-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE CPP #-}

module Development.IDE.Import.FindImports
  ( locateModule
  , locateModuleFile
  , Import(..)
  , ArtifactsLocation(..)
  , modSummaryToArtifactsLocation
  , isBootLocation
  , mkImportDirs
  ) where

import           Control.DeepSeq
import           Development.IDE.GHC.Compat        as Compat
import           Development.IDE.GHC.Error         as ErrUtils
import           Development.IDE.GHC.Orphans       ()
import           Development.IDE.Types.Diagnostics
import           Development.IDE.Types.Location

-- standard imports
import           Control.Monad.Extra
import           Control.Monad.IO.Class
import           Data.List                         (isSuffixOf)
import           Data.Maybe
import           System.FilePath

-- See Note [Guidelines For Using CPP In GHCIDE Import Statements]

#if !MIN_VERSION_ghc(9,3,0)
import           Development.IDE.GHC.Compat.Util
#endif

#if MIN_VERSION_ghc(9,3,0)
import           GHC.Types.PkgQual
import           GHC.Unit.State
#endif

data Import
  = FileImport !ArtifactsLocation
  | PackageImport
  deriving (Show)

data ArtifactsLocation = ArtifactsLocation
  { artifactFilePath    :: !NormalizedFilePath
  , artifactModLocation :: !(Maybe ModLocation)
  , artifactIsSource    :: !Bool          -- ^ True if a module is a source input
  , artifactModule      :: !(Maybe Module)
  } deriving Show

instance NFData ArtifactsLocation where
  rnf ArtifactsLocation{..} = rnf artifactFilePath `seq` rwhnf artifactModLocation `seq` rnf artifactIsSource `seq` rnf artifactModule

isBootLocation :: ArtifactsLocation -> Bool
isBootLocation = not . artifactIsSource

instance NFData Import where
  rnf (FileImport x) = rnf x
  rnf PackageImport  = ()

modSummaryToArtifactsLocation :: NormalizedFilePath -> Maybe ModSummary -> ArtifactsLocation
modSummaryToArtifactsLocation nfp ms = ArtifactsLocation nfp (ms_location <$> ms) source mbMod
  where
    isSource HsSrcFile = True
    isSource _         = False
    source = case ms of
      Nothing     -> "-boot" `isSuffixOf` fromNormalizedFilePath nfp
      Just modSum -> isSource (ms_hsc_src modSum)
    mbMod = ms_mod <$> ms

-- | locate a module in the file system. Where we go from *daml to Haskell
locateModuleFile :: MonadIO m
             => [(UnitId, [FilePath])]
             -> [String]
             -> (ModuleName -> NormalizedFilePath -> m (Maybe NormalizedFilePath))
             -> Bool
             -> ModuleName
             -> m (Maybe (UnitId, NormalizedFilePath))
locateModuleFile import_dirss exts targetFor isSource modName = do
  let candidates import_dirs =
        [ toNormalizedFilePath' (prefix </> moduleNameSlashes modName <.> maybeBoot ext)
           | prefix <- import_dirs , ext <- exts]
  firstJustM go (concat [map (uid,) (candidates dirs) | (uid, dirs) <- import_dirss])
  where
    go (uid, candidate) = fmap ((uid,) <$>) $ targetFor modName candidate
    maybeBoot ext
      | isSource = ext ++ "-boot"
      | otherwise = ext

-- | This function is used to map a package name to a set of import paths.
-- It only returns Just for unit-ids which are possible to import into the
-- current module. In particular, it will return Nothing for 'main' components
-- as they can never be imported into another package.
#if MIN_VERSION_ghc(9,3,0)
mkImportDirs :: HscEnv -> (UnitId, DynFlags) -> Maybe (UnitId, [FilePath])
mkImportDirs _env (i, flags) = Just (i, importPaths flags)
#else
mkImportDirs :: HscEnv -> (UnitId, DynFlags) -> Maybe (PackageName, (UnitId, [FilePath]))
mkImportDirs env (i, flags) = (, (i, importPaths flags)) <$> getUnitName env i
#endif

-- | locate a module in either the file system or the package database. Where we go from *daml to
-- Haskell
locateModule
    :: MonadIO m
    => HscEnv
    -> [(UnitId, DynFlags)] -- ^ Import directories
    -> [String]                        -- ^ File extensions
    -> (ModuleName -> NormalizedFilePath -> m (Maybe NormalizedFilePath))  -- ^ does file exist predicate
    -> Located ModuleName              -- ^ Module name
#if MIN_VERSION_ghc(9,3,0)
    -> PkgQual                -- ^ Package name
#else
    -> Maybe FastString                -- ^ Package name
#endif
    -> Bool                            -- ^ Is boot module
    -> m (Either [FileDiagnostic] Import)
locateModule env comp_info exts targetFor modName mbPkgName isSource = do
  case mbPkgName of
    -- "this" means that we should only look in the current package
#if MIN_VERSION_ghc(9,3,0)
    ThisPkg _ -> do
#else
    Just "this" -> do
#endif
      lookupLocal (homeUnitId_ dflags) (importPaths dflags)
    -- if a package name is given we only go look for a package
#if MIN_VERSION_ghc(9,3,0)
    OtherPkg uid
      | Just dirs <- lookup uid import_paths
          -> lookupLocal uid dirs
#else
    Just pkgName
      | Just (uid, dirs) <- lookup (PackageName pkgName) import_paths
          -> lookupLocal uid dirs
#endif
      | otherwise -> lookupInPackageDB
#if MIN_VERSION_ghc(9,3,0)
    NoPkgQual -> do
#else
    Nothing -> do
#endif

      mbFile <- locateModuleFile ((homeUnitId_ dflags, importPaths dflags) : other_imports) exts targetFor isSource $ unLoc modName
      case mbFile of
        Nothing          -> lookupInPackageDB
        Just (uid, file) -> toModLocation uid file
  where
    dflags = hsc_dflags env
    import_paths = mapMaybe (mkImportDirs env) comp_info
    other_imports =
#if MIN_VERSION_ghc(9,4,0)
      -- On 9.4+ instead of bringing all the units into scope, only bring into scope the units
      -- this one depends on
      -- This way if you have multiple units with the same module names, we won't get confused
      -- For example if unit a imports module M from unit B, when there is also a module M in unit C,
      -- and unit a only depends on unit b, without this logic there is the potential to get confused
      -- about which module unit a imports.
      -- Without multi-component support it is hard to recontruct the dependency environment so
      -- unit a will have both unit b and unit c in scope.
      map (\uid -> (uid, importPaths (homeUnitEnv_dflags (ue_findHomeUnitEnv uid ue)))) hpt_deps
    ue = hsc_unit_env env
    units = homeUnitEnv_units $ ue_findHomeUnitEnv (homeUnitId_ dflags) ue
    hpt_deps :: [UnitId]
    hpt_deps = homeUnitDepends units
#else
      _import_paths'
#endif

      -- first try to find the module as a file. If we can't find it try to find it in the package
      -- database.
      -- Here the importPaths for the current modules are added to the front of the import paths from the other components.
      -- This is particularly important for Paths_* modules which get generated for every component but unless you use it in
      -- each component will end up being found in the wrong place and cause a multi-cradle match failure.
    _import_paths' = -- import_paths' is only used in GHC < 9.4
#if MIN_VERSION_ghc(9,3,0)
            import_paths
#else
            map snd import_paths
#endif

    toModLocation uid file = liftIO $ do
        loc <- mkHomeModLocation dflags (unLoc modName) (fromNormalizedFilePath file)
        let genMod = mkModule (RealUnit $ Definite uid) (unLoc modName)  -- TODO support backpack holes
        return $ Right $ FileImport $ ArtifactsLocation file (Just loc) (not isSource) (Just genMod)

    lookupLocal uid dirs = do
      mbFile <- locateModuleFile [(uid, dirs)] exts targetFor isSource $ unLoc modName
      case mbFile of
        Nothing   -> return $ Left $ notFoundErr env modName $ LookupNotFound []
        Just (uid', file) -> toModLocation uid' file

    lookupInPackageDB = do
      case Compat.lookupModuleWithSuggestions env (unLoc modName) mbPkgName of
        LookupFound _m _pkgConfig -> return $ Right PackageImport
        reason -> return $ Left $ notFoundErr env modName reason

-- | Don't call this on a found module.
notFoundErr :: HscEnv -> Located ModuleName -> LookupResult -> [FileDiagnostic]
notFoundErr env modName reason =
  mkError' $ ppr' $ cannotFindModule env modName0 $ lookupToFindResult reason
  where
    dfs = hsc_dflags env
    mkError' = diagFromString "not found" DiagnosticSeverity_Error (Compat.getLoc modName)
    modName0 = unLoc modName
    ppr' = showSDoc dfs
    -- We convert the lookup result to a find result to reuse GHC's cannotFindModule pretty printer.
    lookupToFindResult =
      \case
        LookupFound _m _pkgConfig ->
          pprPanic "Impossible: called lookupToFind on found module." (ppr modName0)
        LookupMultiple rs -> FoundMultiple rs
        LookupHidden pkg_hiddens mod_hiddens ->
          notFound
             { fr_pkgs_hidden = map (moduleUnit . fst) pkg_hiddens
             , fr_mods_hidden = map (moduleUnit . fst) mod_hiddens
             }
        LookupUnusable unusable ->
          let unusables' = map get_unusable unusable
              get_unusable (m, ModUnusable r) = (moduleUnit m, r)
              get_unusable (_, r) =
                pprPanic "findLookupResult: unexpected origin" (ppr r)
           in notFound {fr_unusables = unusables'}
        LookupNotFound suggest ->
          notFound {fr_suggestions = suggest}

notFound :: FindResult
notFound = NotFound
  { fr_paths = []
  , fr_pkg = Nothing
  , fr_pkgs_hidden = []
  , fr_mods_hidden = []
  , fr_unusables = []
  , fr_suggestions = []
  }
