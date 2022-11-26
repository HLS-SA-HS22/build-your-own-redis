{-# OPTIONS_GHC -Wno-unused-top-binds #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Network.Simple.TCP (serve, HostPreference(HostAny))
import Network.Socket.ByteString (recv, send)
import Control.Monad (forever, guard)
import Data.ByteString (ByteString, pack)
import qualified Data.ByteString.Char8 as B
import Prelude hiding (concat)
import Text.Megaparsec
    ( parse,
      count,
      (<|>),
      Parsec,
      MonadParsec(try),
      Stream(Tokens) )
import Text.Megaparsec.Byte ( crlf, printChar )
import Text.Megaparsec.Byte.Lexer (decimal)
import Data.Void ( Void )
import Data.Either (fromRight)
import Data.Text ( toLower, Text )
import Data.Text.Encoding (decodeUtf8)
import Data.Map (fromList, Map, insert, findWithDefault)
import Data.Map.Internal.Debug (showTree)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, TVar)
import Control.Concurrent.STM.TVar (modifyTVar)
import Data.Time
    ( UTCTime,
      defaultTimeLocale,
      parseTimeOrError,
      addUTCTime,
      diffUTCTime,
      getCurrentTime )

type Request = ByteString
type Response = ByteString
type Parser = Parsec Void Request
type Message = ByteString
type Key = ByteString
type Value = ByteString
type DB = Map Key (Value, Expiry)
type Time = Maybe Integer
type Expiry = UTCTime

data Command = Ping
             | Echo Message
             | Set Key Value Time
             | Get Key
             | Error ApplicationError
data ApplicationError = UnknownCommand
data Configuration = Configuration {
    port :: String,
    recvBytes :: Int,
    pingDefault :: ByteString,
    setSuccess :: ByteString,
    nilString :: ByteString,
    noExpiry :: ByteString,
    timeFormat :: String
}

main :: IO ()
main = do
    putStrLn $ "\r\n>>> Redis server listening on port " ++ port redisConfig ++ " <<<"
    redisDB <- setupDB
    serve HostAny (port redisConfig) $ \(socket, _address) -> do
        putStrLn $ "successfully connected client: " ++ show _address
        _ <- forever $ do
            request <- recv socket $ recvBytes redisConfig
            response <- exec (parseRequest request) redisDB
            _ <- send socket (encodeRESP response)

            -- debug database
            out <- readTVarIO redisDB
            putStrLn $ "\r\n***\r\nRedis DB content:\r\n"++ showTree out ++ "***\r\n"
        putStrLn $ "disconnected client: " ++ show _address

redisConfig :: Configuration
redisConfig = Configuration "6379" 2048 "PONG" "OK" "(nil)"
                            "2222-12-31T23:59:59" "%Y-%m-%dT%H:%M:%S%Q"

toUTCTime :: ByteString -> UTCTime
toUTCTime t = parseTimeOrError True defaultTimeLocale (timeFormat redisConfig) $ B.unpack t

noExpiryUTC :: UTCTime
noExpiryUTC = toUTCTime $ noExpiry redisConfig

setupDB :: IO (TVar DB)
setupDB = newTVarIO $ fromList [("__version__", ("1.0.0", noExpiryUTC))]

encodeRESP :: Response -> Response
encodeRESP s | s == nilString redisConfig = B.concat ["$", "-1", "\r\n"]
             | otherwise = B.concat ["+", s, "\r\n"]

exec :: Command -> TVar DB -> IO Response
exec Ping _ = return "PONG"
exec (Echo msg) _ = return msg
exec (Set key value time) db = set key value time db
exec (Get key) db = get key db
exec (Error UnknownCommand) _ = return "-ERR Unknown Command"

parseRequest :: Request -> Command
parseRequest req = fromRight err response
    where
        err = Error UnknownCommand
        response = parse parseToCommand "" req

parseToCommand :: Parser Command
parseToCommand = try parseEcho
             <|> try parsePing
             <|> try parseSet
             <|> try parseGet

cmpIgnoreCase :: Text -> Text -> Bool
cmpIgnoreCase a b = toLower a == toLower b

-- some tools escape backslashes
crlfAlt :: Parser (Tokens ByteString)
crlfAlt = "\\r\\n" <|> crlf

redisBulkString :: Parser Response
redisBulkString = do
    _ <- "$"  -- Redis Bulk Strings start with $
    n <- decimal
    guard $ n >= 0
    _ <- crlfAlt
    s <- count n printChar
    return $ pack s

commandCheck :: Text -> Parser (Integer, Response)
commandCheck c = do
    _ <- "*"  -- Redis Arrays start with *
    n <- decimal
    guard $ n > 0
    cmd <- crlfAlt *> redisBulkString
    guard $ cmpIgnoreCase (decodeUtf8 cmd) c
    return (n, cmd)

redisOptionCheck :: Text -> Parser ()
redisOptionCheck opt = do
    o <- redisBulkString
    guard $ cmpIgnoreCase (decodeUtf8 o) opt
    return ()

redisInteger :: Parser Integer
redisInteger = do
    _ <- "$"  -- Redis Bulk Strings start with $
    n <- decimal
    guard $ (n::Integer) >= 0
    _ <- crlfAlt
    decimal

parseEcho :: Parser Command
parseEcho = do
    (n, _) <- commandCheck "echo"
    guard $ n == 2
    message <- crlfAlt *> redisBulkString
    return $ Echo message

parsePing :: Parser Command
parsePing = do
    (n, _) <- commandCheck "ping"
    guard $ n == 1
    return Ping

parseSet :: Parser Command
parseSet = do
    (n, _) <- commandCheck "set"
    guard $ n >= 3
    key <- crlfAlt *> redisBulkString
    value <- crlfAlt *> redisBulkString
    time <- if n >= 4 then do
        _ <- crlfAlt *> redisOptionCheck "px" -- Redis: px for milliseconds
        t <- crlfAlt *> redisInteger
        return $ Just t
        else return Nothing
    return $ Set key value time

parseGet :: Parser Command
parseGet = do
    (n, _) <- commandCheck "get"
    guard $ n == 2
    key <- crlfAlt *> redisBulkString
    return $ Get key

set :: Key -> Value -> Time -> TVar DB -> IO Response
set key val expiry db = do
    time <- case expiry of
                Just ms -> addUTCTime (fromInteger ms/1000) <$> getCurrentTime
                Nothing -> return noExpiryUTC
    _ <- atomically $ modifyTVar db $ insert key (val, time)
    return $ setSuccess redisConfig

get :: Key -> TVar DB -> IO Response
get key db = do
    (val, t) <- getValTime key <$> readTVarIO db
    checkExpiry (val, t) <$> getCurrentTime

getValTime :: Key -> DB -> (Value, UTCTime)
getValTime key db = do
    let err = (nilString redisConfig, noExpiryUTC)
    findWithDefault err key db

checkExpiry :: (Value, UTCTime) -> UTCTime -> ByteString
checkExpiry (val, dbTime) sysTime =
    if isExpired dbTime sysTime then
        nilString redisConfig
        else val

-- diff: t1 - t2
isExpired :: UTCTime -> UTCTime -> Bool
isExpired t1 t2 = diffUTCTime t1 t2 < 0