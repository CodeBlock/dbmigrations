module Database.Schema.Migrations.Filesystem
    ( newFilesystemStore

    , FilesystemStore
    , storePath
    , migrationMap

    , MigrationMap
    )
where

import System.Directory ( getDirectoryContents, doesFileExist )
import System.FilePath ( takeDirectory, takeFileName, (</>) )
import System.IO ( putStrLn )

import qualified Data.Map as Map
import Data.Time.Clock ( UTCTime )
import Data.Time () -- for UTCTime Show instance
import Data.Maybe ( catMaybes )
import Data.Maybe ( isNothing, isJust )

import Text.ParserCombinators.Parsec

import Control.Monad ( filterM, when, mapM_ )
import Control.Monad.Trans ( liftIO )
import Control.Monad.State ( StateT, get, put, execStateT )

import Database.Schema.Migrations.Migration
    ( Migration(..)
    , MigrationID
    , newMigration
    )

-- |Code for parsing and serializing Migrations to disk files, and an
-- instance of MigrationStore for filesystem-backed migrations.

type MigrationMap = Map.Map MigrationID Migration
type FieldName = String
type FieldProcessor = String -> Migration -> Maybe Migration

data FilesystemStore = FSStore { storePath :: FilePath
                               , migrationMap :: MigrationMap }

-- |Create a new filesystem store by loading all migrations at the
-- specified filesystem path.
newFilesystemStore :: FilePath -> IO FilesystemStore
newFilesystemStore path = do
  migrations <- execStateT (loadMigrations path) Map.empty
  return $ FSStore { storePath = path
                   , migrationMap = migrations }

-- |Given a directory path, return a list of all files in the
-- directory, not including the special directories "." and "..".
filesInDirectory :: FilePath -> IO [FilePath]
filesInDirectory path = do
  contents <- getDirectoryContents path
  let withPath = map (path </>) nonSpecial
      nonSpecial = [ f | f <- contents, not (f `elem` [".", ".."]) ]
  liftIO $ filterM doesFileExist withPath

-- |Load migrations recursively from the specified path into the
-- MigrationMap state.
loadMigrations :: FilePath -> StateT MigrationMap IO ()
loadMigrations path = (liftIO $ filesInDirectory path) >>= mapM_ loadWithDeps

-- |Given a file path, return its corresponding migration ID.
migrationIdFromPath :: FilePath -> MigrationID
migrationIdFromPath = takeFileName

-- |Given a file path, load the migration at the specified path and,
-- if necessary, recursively load its dependencies into the
-- MigrationMap state.
loadWithDeps :: FilePath -> StateT MigrationMap IO ()
loadWithDeps path = do
  let parent = takeDirectory path
      mid = migrationIdFromPath path
  currentMap <- get
  when (isNothing $ Map.lookup mid currentMap) $
       do
         result <- liftIO $ migrationFromFile path
         case result of
           Nothing -> fail ("Could not load migration from file " ++ path)
           Just (m, depIds) -> do
                        mapM_ (\p -> loadWithDeps $ parent </> p) depIds
                        newMap <- get
                        let newM = m { mDeps = loadedDeps }
                            loadedDeps = catMaybes $ map (\i -> Map.lookup i newMap) depIds

                        put $ Map.insert (mId m) newM newMap

-- |Given a file path, read and parse the migration at the specified
-- path and, if successful, return the migration and its claimed
-- dependencies.
migrationFromFile :: FilePath -> IO (Maybe (Migration, [MigrationID]))
migrationFromFile path = do
  contents <- readFile path
  let migrationId = migrationIdFromPath path
  case parse migrationParser path contents of
    Left e -> fail $ "Could not parse migration file " ++ path
    Right (fields, depIds) ->
        do
          newM <- newMigration ""
          case migrationFromFields newM fields of
            Nothing -> fail $ "Unrecognized field in migration " ++ (show path)
            Just m -> return $ Just (m { mId = migrationId }, depIds)

-- |Given a migration and a list of parsed migration fields, update
-- the migration from the field values for recognized fields.
migrationFromFields :: Migration -> [(FieldName, String)] -> Maybe Migration
migrationFromFields m [] = Just m
migrationFromFields m ((name, value):rest) = do
  processor <- lookup name fieldProcessors
  newM <- processor value m
  migrationFromFields newM rest

fieldProcessors :: [(FieldName, FieldProcessor)]
fieldProcessors = [ ("Created", setTimestamp )
                  , ("Description", setDescription )
                  , ("Apply", setApply )
                  , ("Revert", setRevert )
                  , ("Depends", nullFieldProcessor)
                  ]

nullFieldProcessor :: FieldProcessor
nullFieldProcessor _ m = Just m

setTimestamp :: FieldProcessor
setTimestamp value m = do
  ts <- case readTimestamp value of
          [(t, _)] -> return t
          _ -> fail "expected only one parse"
  return $ m { mTimestamp = ts }

readTimestamp :: String -> [(UTCTime, String)]
readTimestamp = reads

setDescription :: FieldProcessor
setDescription desc m = Just $ m { mDesc = Just desc }

setApply :: FieldProcessor
setApply apply m = Just $ m { mApply = apply }

setRevert :: FieldProcessor
setRevert revert m = Just $ m { mRevert = Just revert }

-- |Parse a migration document and return a list of parsed fields and
-- a list of claimed dependencies.
migrationParser :: Parser ([(FieldName, String)], [MigrationID])
migrationParser = do
  fields <- many parseField
  depIds <- case lookup "Depends" fields of
              Nothing -> fail "'Depends' field missing from migration file"
              Just f -> do
                    case parse parseDepsList "-" f of
                      Left e -> fail $ show e
                      Right ids -> return ids
  return (fields, depIds)

parseDepsList :: Parser [MigrationID]
parseDepsList = sepBy parseMID whitespace
    where
      parseMID = many1 (alphaNum <|> oneOf "-._")

discard :: Parser a -> Parser ()
discard = (>> return ())

eol :: Parser ()
eol = (discard newline) <|> (discard eof)

whitespace :: Parser ()
whitespace = discard $ oneOf " \t"

requiredWhitespace :: Parser ()
requiredWhitespace = discard $ many1 whitespace

parseFieldName :: Parser FieldName
parseFieldName = many1 (alphaNum <|> char '-')

parseField :: Parser (FieldName, String)
parseField = do
  name <- parseFieldName
  char ':'
  many whitespace
  rest <- manyTill anyChar eol
  otherLines <- otherContentLines
  let value = rest ++ (concat otherLines)
  return (name, value)

otherContentLines :: Parser [String]
otherContentLines =
    many $ try $ do
      requiredWhitespace
      manyTill anyChar eol >>= return . (" " ++)