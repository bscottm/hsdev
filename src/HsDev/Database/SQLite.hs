{-# LANGUAGE OverloadedStrings, TypeOperators, TypeApplications #-}

module HsDev.Database.SQLite (
	initialize, purge,
	query, query_, execute, execute_,
	updatePackageDb, removePackageDb, insertPackageDb,
	updateProject, removeProject, insertProject, insertBuildInfo,
	updateModule, removeModule, insertModule, insertModuleSymbols,
	lookupModuleLocation, lookupModule, insertLookupModule,
	lookupSymbol, insertLookupSymbol,
	lastRow,

	loadModules,

	-- * Reexports
	module Database.SQLite.Simple,
	module HsDev.Database.SQLite.Select
	) where

import Control.Lens
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson
import Data.Maybe
import Data.String
import Data.Text (Text)
import Database.SQLite.Simple hiding (query, query_, execute, execute_)
import qualified Database.SQLite.Simple as SQL (query, query_, execute, execute_)
import Distribution.Text (display)
import Language.Haskell.Extension ()
import System.Log.Simple
import Text.Format

import System.Directory.Paths

import HsDev.Database.SQLite.Instances ()
import HsDev.Database.SQLite.Schema
import HsDev.Database.SQLite.Select
import qualified HsDev.Display as Display
import HsDev.PackageDb.Types
import HsDev.Project.Types
import HsDev.Symbols.Types
import qualified HsDev.Symbols.Parsed as P
import qualified HsDev.Symbols.Name as Name
import HsDev.Server.Types
import HsDev.Util

-- | Initialize database
initialize :: String -> IO Connection
initialize p = do
	conn <- open p
	[(Only hasTables)] <- SQL.query_ conn "select count(*) > 0 from sqlite_master where type == 'table';"
	when (not hasTables) $ mapM_ (SQL.execute_ conn) commands
	return conn

purge :: SessionMonad m => m ()
purge = do
	tables <- query_ @(Only String) "select name from sqlite_master where type == 'table';"
	forM_ tables $ \(Only table) ->
		execute_ $ fromString $ "delete from {};" ~~ table

query :: (ToRow q, FromRow r, SessionMonad m) => Query -> q -> m [r]
query q' params = do
	conn <- serverSqlDatabase
	liftIO $ SQL.query conn q' params

query_ :: (FromRow r, SessionMonad m) => Query -> m [r]
query_ q' = do
	conn <- serverSqlDatabase
	liftIO $ SQL.query_ conn q'

execute :: (ToRow q, SessionMonad m) => Query -> q -> m ()
execute q' params = do
	conn <- serverSqlDatabase
	liftIO $ SQL.execute conn q' params

execute_ :: SessionMonad m => Query -> m ()
execute_ q' = do
	conn <- serverSqlDatabase
	liftIO $ SQL.execute_ conn q'

updatePackageDb :: SessionMonad m => PackageDb -> [ModulePackage] -> m ()
updatePackageDb pdb pkgs = scope "update-package-db" $ do
	sendLog Trace $ "update package-db: {}" ~~ Display.display pdb
	removePackageDb pdb
	insertPackageDb pdb pkgs

removePackageDb :: SessionMonad m => PackageDb -> m ()
removePackageDb pdb = scope "remove-package-db" $
	execute "delete from package_dbs where package_db == ?;" (Only $ showPackageDb pdb)

insertPackageDb :: SessionMonad m => PackageDb -> [ModulePackage] -> m ()
insertPackageDb pdb pkgs = scope "insert-package-db" $ forM_ pkgs $ \pkg -> do
	execute
		"insert into package_dbs (package_db, package_name, package_version) values (?, ?, ?);"
		(showPackageDb pdb, pkg ^. packageName, pkg ^. packageVersion)

updateProject :: SessionMonad m => Project -> Maybe PackageDbStack -> m ()
updateProject proj pdbs = scope "update-project" $ do
	sendLog Trace $ "update project: {}" ~~ Display.display proj
	removeProject proj
	insertProject proj pdbs

removeProject :: SessionMonad m => Project -> m ()
removeProject proj = scope "remove-project" $ do
	projId <- query @_ @(Only Int) "select id from projects where cabal == ?;" (Only $ proj ^. projectCabal)
	case projId of
		[] -> return ()
		pids -> do
			when (length pids > 1) $ do
				sendLog Warning $ "multiple projects for cabal {} found" ~~ (proj ^. projectCabal)
			forM_ pids $ \pid -> do
				bids <- query @_ @(Only Int) "select build_info_id from targets where project_id == ?;" pid
				execute "delete from projects where id == ?;" pid
				execute "delete from libraries where project_id == ?;" pid
				execute "delete from executables where project_id == ?;" pid
				execute "delete from tests where project_id == ?;" pid
				forM_ bids $ \bid -> execute "delete from build_infos where id == ?;" bid

insertProject :: SessionMonad m => Project -> Maybe PackageDbStack -> m ()
insertProject proj pdbs = scope "insert-project" $ do
	execute "insert into projects (name, cabal, version, package_db_stack) values (?, ?, ?, ?);" (
		proj ^. projectName,
		proj ^. projectCabal . path,
		proj ^? projectDescription . _Just . projectVersion,
		fmap (encode . map showPackageDb . packageDbs) pdbs)
	projId <- lastRow

	forM_ (proj ^? projectDescription . _Just . projectLibrary . _Just) $ \lib -> do
		buildInfoId <- insertBuildInfo $ lib ^. libraryBuildInfo
		execute "insert into libraries (project_id, modules, build_info_id) values (?, ?, ?);"
			(projId, encode $ lib ^. libraryModules, buildInfoId)

	forM_ (proj ^.. projectDescription . _Just . projectExecutables . each) $ \exe -> do
		buildInfoId <- insertBuildInfo $ exe ^. executableBuildInfo
		execute "insert into executables (project_id, name, path, build_info_id) values (?, ?, ?, ?);"
			(projId, exe ^. executableName, exe ^. executablePath . path, buildInfoId)

	forM_ (proj ^.. projectDescription . _Just . projectTests . each) $ \test -> do
		buildInfoId <- insertBuildInfo $ test ^. testBuildInfo
		execute "insert into tests (project_id, name, enabled, main, build_info_id) values (?, ?, ?, ?, ?);"
			(projId, test ^. testName, test ^. testEnabled, test ^? testMain . _Just . path, buildInfoId)

insertBuildInfo :: SessionMonad m => Info -> m Int
insertBuildInfo info = scope "insert-build-info" $ do
	execute "insert into build_infos (depends, language, extensions, ghc_options, source_dirs, other_modules) values (?, ?, ?, ?, ?, ?);" (
			encode $ info ^. infoDepends,
			fmap display $ info ^. infoLanguage,
			encode $ map display $ info ^. infoExtensions,
			encode $ info ^. infoGHCOptions,
			encode $ info ^.. infoSourceDirs . each . path,
			encode $ info ^. infoOtherModules)
	lastRow

updateModule :: SessionMonad m => InspectedModule -> m ()
updateModule im = scope "update-module" $ do
	sendLog Trace $ "update module: {}" ~~ Display.display (im ^. inspectedKey)
	mmid <- lookupModuleLocation (im ^. inspectedKey)
	case mmid of
		Just mid -> removeModule mid
		Nothing -> return ()
	insertModule im
	insertModuleSymbols im

removeModule :: SessionMonad m => Int -> m ()
removeModule mid = scope "remove-module" $ do
	sids <- query @_ @(Only Int) "select id from symbols where module_id == ?;" (Only mid)
	forM_ sids $ \sid -> do
		execute "delete from exports where symbol_id == ?;" sid
		execute "delete from scopes where symbol_id == ?;" sid
	execute "delete from symbols where module_id == ?;" (Only mid)
	execute "delete from exports where module_id == ?;" (Only mid)
	execute "delete from scopes where module_id == ?;" (Only mid)
	execute "delete from names where module_id == ?;" (Only mid)
	execute "delete from modules where id == ?;" (Only mid)

insertModule :: SessionMonad m => InspectedModule -> m ()
insertModule im = scope "insert-module" $ do
	execute "insert into modules (file, cabal, install_dirs, package_name, package_version, other_location, name, docs, fixities, tag, inspection_error) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);" $ (
		im ^? inspectedKey . moduleFile . path,
		im ^? inspectedKey . moduleProject . _Just . projectCabal,
		fmap (encode . map (view path)) (im ^? inspectedKey . moduleInstallDirs),
		im ^? inspectedKey . modulePackage . _Just . packageName,
		im ^? inspectedKey . modulePackage . _Just . packageVersion,
		im ^? inspectedKey . otherLocationName)
		:. (
		msum [im ^? inspected . moduleId . moduleName, im ^? inspectedKey . installedModuleName],
		im ^? inspected . moduleDocs,
		fmap encode $ im ^? inspected . moduleFixities,
		encode $ im ^. inspectionTags,
		fmap show $ im ^? inspectionResult . _Left)

insertModuleSymbols :: SessionMonad m => InspectedModule -> m ()
insertModuleSymbols im = scope "insert-module-symbols" $ do
	[Only mid] <- query "select id from modules where file is ? and package_name is ? and package_version is ? and other_location is ? and (name is ? or ? is null);" (
		im ^? inspectedKey . moduleFile . path,
		im ^? inspectedKey . modulePackage . _Just . packageName,
		im ^? inspectedKey . modulePackage . _Just . packageVersion,
		im ^? inspectedKey . otherLocationName,
		im ^? inspectedKey . installedModuleName,
		im ^? inspectedKey . installedModuleName)
	forM_ (im ^.. inspected . moduleExports . each) (insertExportSymbol mid)
	forM_ (im ^.. inspected . scopeSymbols) (uncurry $ insertScopeSymbol mid)
	forM_ (im ^.. inspected . moduleSource . _Just . P.qnames) (insertResolvedName mid)
	where
		insertExportSymbol :: SessionMonad m => Int -> Symbol -> m ()
		insertExportSymbol mid sym = scope "export" $ do
			defMid <- insertLookupModule (sym ^. symbolId . symbolModule)
			sid <- insertLookupSymbol defMid sym
			execute "insert into exports (module_id, symbol_id) values (?, ?);" (mid, sid)

		insertScopeSymbol :: SessionMonad m => Int -> Symbol -> [Name] -> m ()
		insertScopeSymbol mid sym names = scope "scope" $ do
			defMid <- insertLookupModule (sym ^. symbolId . symbolModule)
			sid <- insertLookupSymbol defMid sym
			forM_ names $ \name -> execute "insert into scopes (module_id, qualifier, name, symbol_id) values (?, ?, ?, ?);" (
				mid,
				Name.nameModule name,
				Name.nameIdent name,
				sid)

		insertResolvedName mid qname = scope "names" $ do
			execute "insert into names (module_id, qualifier, name, line, column, line_to, column_to, def_line, def_column, resolved_module, resolved_name, resolve_error) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);" $ (
				mid,
				Name.nameModule $ void qname,
				Name.nameIdent $ void qname,
				qname ^. P.pos . positionLine,
				qname ^. P.pos . positionColumn,
				qname ^. P.regionL . regionTo . positionLine,
				qname ^. P.regionL . regionTo . positionColumn)
				:. (
				qname ^? P.defPos . positionLine,
				qname ^? P.defPos . positionColumn,
				(qname ^? P.resolvedName) >>= Name.nameModule,
				Name.nameIdent <$> (qname ^? P.resolvedName),
				P.resolveError qname)

lookupModuleLocation :: SessionMonad m => ModuleLocation -> m (Maybe Int)
lookupModuleLocation m = do
	mids <- query "select id from modules where ((? is null) or (name == ?)) and file is ? and package_name is ? and package_version is ? and other_location is ?;" (
		m ^? installedModuleName,
		m ^? installedModuleName,
		m ^? moduleFile . path,
		m ^? modulePackage . _Just . packageName,
		m ^? modulePackage . _Just . packageVersion,
		m ^? otherLocationName)
	when (length mids > 1) $ sendLog Warning  $ "different modules with location: {}" ~~ Display.display m
	return $ listToMaybe [mid | Only mid <- mids]

lookupModule :: SessionMonad m => ModuleId -> m (Maybe Int)
lookupModule m = do
	mids <- query "select id from modules where name is ? and file is ? and package_name is ? and package_version is ? and other_location is ?;" (
		m ^. moduleName,
		m ^? moduleLocation . moduleFile . path,
		m ^? moduleLocation . modulePackage . _Just . packageName,
		m ^? moduleLocation . modulePackage . _Just . packageVersion,
		m ^? moduleLocation . otherLocationName)
	when (length mids > 1) $ sendLog Warning  $ "different modules with same name and location: {}" ~~ (m ^. moduleName)
	return $ listToMaybe [mid | Only mid <- mids]

insertLookupModule :: SessionMonad m => ModuleId -> m Int
insertLookupModule m = do
	modId <- lookupModule m
	case modId of
		Just mid -> return mid
		Nothing -> do
			execute "insert into modules (file, cabal, install_dirs, package_name, package_version, other_location, name) values (?, ?, ?, ?, ?, ?, ?);" (
				m ^? moduleLocation . moduleFile . path,
				m ^? moduleLocation . moduleProject . _Just . projectCabal,
				fmap (encode . map (view path)) (m ^? moduleLocation . moduleInstallDirs),
				m ^? moduleLocation . modulePackage . _Just . packageName,
				m ^? moduleLocation . modulePackage . _Just . packageVersion,
				m ^? moduleLocation . otherLocationName,
				m ^. moduleName)
			lastRow

lookupSymbol :: SessionMonad m => Int -> Symbol -> m (Maybe Int)
lookupSymbol mid sym = do
	sids <- query "select id from symbols where name is ? and module_id is ?;" (
		sym ^. symbolId . symbolName,
		mid)
	when (length sids > 1) $ sendLog Warning $ "different symbols with same module id: {}.{}" ~~ show mid ~~ (sym ^. symbolId . symbolName)
	return $ listToMaybe [sid | Only sid <- sids]

insertLookupSymbol :: SessionMonad m => Int -> Symbol -> m Int
insertLookupSymbol mid sym = do
	msid <- lookupSymbol mid sym
	case msid of
		Just sid -> return sid
		Nothing -> do
			execute "insert into symbols (name, module_id, docs, line, column, what, type, parent, constructors, args, context, associate, pat_type, pat_constructor) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);" $ (
				sym ^. symbolId . symbolName,
				mid,
				sym ^. symbolDocs,
				sym ^? symbolPosition . _Just . positionLine,
				sym ^? symbolPosition . _Just . positionColumn)
				:. (
				symbolType sym,
				sym ^? symbolInfo . functionType . _Just,
				msum [sym ^? symbolInfo . parentClass, sym ^? symbolInfo . parentType],
				encode $ sym ^? symbolInfo . selectorConstructors,
				encode $ sym ^? symbolInfo . typeArgs,
				encode $ sym ^? symbolInfo . typeContext,
				sym ^? symbolInfo . familyAssociate . _Just,
				sym ^? symbolInfo . patternType . _Just,
				sym ^? symbolInfo . patternConstructor)
			lastRow

lastRow :: SessionMonad m => m Int
lastRow = do
	[Only i] <- query_ "select last_insert_rowid();"
	return i

loadModules :: (SessionMonad m, ToRow q) => String -> q -> m [Module]
loadModules selectExpr args = do
	ms <- query @_ @(ModuleId :. (Maybe Text, Maybe Value, Int)) (toQuery (qModuleId `mappend` select_ ["mu.docs", "mu.fixities", "mu.id"] [] [fromString $ "mu.id in (" ++ selectExpr ++ ")"])) args
	forM ms $ \(mid' :. (mdocs, mfixities, mid)) -> do
		syms <- query @_ @Symbol (toQuery (qSymbol `mappend` select_ [] ["exports as e"] ["e.module_id == ?", "e.symbol_id == s.id"])) (Only mid)
		return $ Module {
			_moduleId = mid',
			_moduleDocs = mdocs,
			_moduleExports = syms,
			_moduleFixities = fromMaybe [] (mfixities >>= fromJSON'),
			_moduleScope = mempty,
			_moduleSource = Nothing }

showPackageDb :: PackageDb -> String
showPackageDb GlobalDb = "global"
showPackageDb UserDb = "user"
showPackageDb (PackageDb p) = p ^. path
