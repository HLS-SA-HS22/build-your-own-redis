In stage 7 the option to expire the validity of a key is implemented.

Redis specifies various options with which certain commands can be extended.
In this particular case, the option `px` in the `set` command specifies the number of milliseconds for which a key is valid.
The syntax looks like: `set key value px 1000` to set the expiration of the key 1 second from now.

# 1. Extend the database
Since each key-value pair has its own expiration time, we need to add another entry to the database where the time of expiration is stored.
Expanding the current database is only possible by adding another element to the value part.
This is best done by adding another tuple which contains the value and the expiration time.

```haskell
type Expiry = UTCTime
type DB = Map Key (Value, Expiry)
```
The type `UTCTime` is from the [time](https://hackage.haskell.org/package/time) library and is exposed through the `Data.Time` package.
This package also comes with other helper functions to process `UTCTime`, which by default tracks time in seconds, but can also have precision of picoseconds.

You should now extend the database to also contain the expiration time.
By default, we expect a key to be valid "forever" if nothing is specified.
In this case, "forever" is just a time very far in the future we call `noExpiry`.
We can add this time as another constant to our existing `redisConfig`.

However, the `UTCTime` type is tracking time in seconds and we want to avoid having to make the conversion from a human-readable format by hand.
It is easier for us to define the time as a `ByteString`.
The `time` library has a function which does this transformation, given that a time format is specified.
The default format is again defined as a constant.

```haskell
toUTCTime :: ByteString -> UTCTime
toUTCTime t = parseTimeOrError True defaultTimeLocale (timeFormat redisConfig) $ B.unpack t
```

Converting the `noExpiry` to `UTCTime` is a common operation which will happen a number of times during the program.
We therefore define a function for it, `noExpiryUTC`.

```haskell
noExpiryUTC :: UTCTime
noExpiryUTC = toUTCTime $ noExpiry redisConfig
```

We can now add the tuple of `(Value, UTCTime)` to the database.

```haskell
setupDB :: IO (TVar DB)
setupDB = newTVarIO $ fromList [("__version__", ("1.0.0", noExpiryUTC))]
```

# 2. Set expiry
We start with implementing the expiration functionality in the `set` function.
Similar to when we added the parser, we start with the basic building blocks.

First, we extend the `Set` constructor for the type `Command` to also accept a time value.
Then, we extend the pattern matching for `Set` in the `exec` function, too.
We can add another type synonym for `Time`, which is of type `Maybe Integer`, but more on this choice later.

```haskell
type Time = Maybe Integer

data Command = ...
             | Set Key Value Time
             ...

exec :: Command -> TVar DB -> IO Response
...
exec (Set key value time) db = set key value time db
...
```

Since the `px` option consists of the term `px` and an integer value, we can parse this likewise to extracting the command.
Consequently, we can check if `px` is actually the option by defining another check-function, `redisOptionCheck`, comparable to the `commandCheck`.
We leverage again the `redisBulkString` function to process the Bulk String that should contain `px`.

```haskell
redisOptionCheck :: Text -> Parser ()
redisOptionCheck opt = do
    o <- redisBulkString
    guard $ cmpIgnoreCase (decodeUtf8 o) opt
    return ()
```

The number of milliseconds follow the `px` option.
Since this number is transmitted as a `ByteString`, it would be ideal to instantly transform it to an `Integer`, so that we can process it more easily to `UTCTime`.
When parsing a request, we can simply tell the parser that what follows is an `Integer`.

However, instead of using the `redisBulkString` function, which only parses `ByteString`s, we define another parser that parses `Integer`.
Instead of the counting the printable characters using `printChar` we simply process and return the decimals that follow using `decimal`.

```haskell
redisInteger :: Parser Integer
redisInteger = do
    _ <- "$"  -- Redis Bulk Strings start with $
    n <- decimal
    guard $ (n::Integer) >= 0
    _ <- crlfAlt
    decimal
```

We can now add these to parser to the `parseSet` function to process the milliseconds.
The milliseconds are stored in the `time` variable and are then added to the overall return.

```haskell
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
```

You noticed that we treat `time` as a `Maybe` type.
If no option is specified, then no expiration should be set.
This is best solved by returning `Just time`, or `Nothing` otherwise.

We will distinguish these two cases in the `set` function.
But first we have to expand the type signature to also accept `Time`, which is a type synonym for `type Time = Maybe Integer`.

To add the milliseconds to the current system time, we extract them by using `getCurrentTime` and add the seconds which we converted from the milliseconds.
The `addUTCTime` function from the `time` library does this addition for us.

```haskell
set :: Key -> Value -> Time -> TVar DB -> IO Response
set key val expiry db = do
    time <- case expiry of
                Just ms -> addUTCTime (fromInteger ms/1000) <$> getCurrentTime
                Nothing -> return noExpiryUTC
    _ <- atomically $ modifyTVar db $ insert key (val, time)
    return $ setSuccess redisConfig
```

If no expiration was set, i.e. a simple `set key value` command was issued by the user, we want to treat the key-value pair as being valid "forever" by using `noExpiryUTC`.

Otherwise, the `set` function remains the same, and we can now focus on `get`.

# 3. Get expiry

When you look up a key, you have to check now if it is still valid, i.e. not expired.
In order to simplify things a bit, we only check the expiration when a key is queried, which is also the default behavior of Redis.

To check if a time is different to another, the `time` library has a function `diffUTCTime` that does exactly that.
It takes two time values and subtracts them.
Since we are interested if the expiration time of a key predates the current time, meaning that it is smaller, we simply check if the result is smaller than zero.
We chose to use a `Bool` so that we can differentiate the two cases easily.

```haskell
isExpired :: UTCTime -> UTCTime -> Bool
isExpired t1 t2 = diffUTCTime t1 t2 < 0
```

Our goal is to return the `Value` of a `Key` if it has not expired, and `(nil)`, if it is no longer valid.
To achieve this, we require the expiration time of the key along with the current system time and return either the key's value or nil.

We could do this within the `get` function itself, or to keep things a bit tidier, we create another helper function with that logic.
This function, we call it `checkExpiry`, takes the output from the database, i.e. the `(Value, UTCTime)` tuple along with the system time.

```haskell
checkExpiry :: (Value, UTCTime) -> UTCTime -> ByteString
checkExpiry (val, dbTime) sysTime =
    if isExpired dbTime sysTime then
        nilString redisConfig
        else val
```

The `get` function requires a small adjustment in that we have to transform it to use the `do` notation to better handle the different operations.

We also outsource the retrieving of the `Value` and `UTCTime` from the database into a separate function, `getValTime` that includes `findWithDefault`.
Since the the database returns a tuple of `Value` and `UTCTime`, the error value for the `findWithDefault` function has to be in the same type now.
The time component is merely a placeholder, since the relevant error is "(nil)" from the constant.
To achieve this we can pass it the already existing `noExpiryUTC` time as a default error value.

```haskell
getValTime :: Key -> DB -> (Value, UTCTime)
getValTime key db = do
    let err = (nilString redisConfig, noExpiryUTC)
    findWithDefault err key db
```

Let us turn to the `get` function and add both, the `getValTime` and the `checkExpiry` functions.
We can again use the applicative functor `<$>` to apply `getValTime` and `checkExpiry` to reading the database and the current system time, respectively.

```haskell
get :: Key -> TVar DB -> IO Response
get key db = do
    (val, t) <- getValTime key <$> readTVarIO db
    checkExpiry (val, t) <$> getCurrentTime
```

# 4. Null Bulk String 

The "(nil)" value that is returned by the `get` function when either a key does not exist or has expired, is specified by Redis to also be an empty or [Null Bulk String](https://redis.io/docs/reference/protocol-spec/#resp-bulk-strings).

This stage of the challenge expects the "(nil)" value to be such a `Null Bulk String`.
It is defined as `$-1\r\n` so we can do a simple conversion in the `encodeRESP` function.

```haskell
encodeRESP :: Response -> Response
encodeRESP s | s == nilString redisConfig = B.concat ["$", "-1", "\r\n"]
             | otherwise = B.concat ["+", s, "\r\n"]
```

With that in place the full functionality up to this stage is completed.