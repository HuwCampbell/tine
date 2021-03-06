{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Tine.Conduit (
    Out
  , WithEnv (..)
  , StreamingProcessOrPin (..)
  , xPutStrLn
  , capture
  , exec
  , raw
  , execOrTerminateOnPin
  , xproc
  , xprocAt
  , inDirectory
  , hoistExit
  , hoistExitM
  , withEnv
  ) where

import           Control.Concurrent.Async (Concurrently (..), async, cancel, waitEither)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.IO.Class (MonadIO (..))

import           Data.ByteString (ByteString)
import           Data.Conduit (Sink, (=$=), ($$))
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import qualified Data.Conduit.Process as CP
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import           P

import           System.Environment (getEnvironment)
import           System.Exit (ExitCode (..))
import           System.IO (IO, FilePath)
import           System.Process (CreateProcess (..), proc)

import           Tine.Process (terminate)
import           Twine.Data.Pin (Pin, waitForPin)

import           X.Control.Monad.Trans.Either (EitherT, left)

data WithEnv =
    InheritEnv Text
  | SetEnv Text Text
    deriving (Eq, Show)

type Out =
  Sink ByteString IO ()

data StreamingProcessOrPin =
    StreamingProcessStopped ExitCode
  | StreamingPinPulled ExitCode
    deriving (Eq, Show)


xPutStrLn :: MonadIO m => Out -> Text -> m ()
xPutStrLn o t =
  liftIO $ CL.sourceList (fmap T.encodeUtf8 [t, "\n"]) $$ o

capture :: Sink ByteString IO a -> Sink ByteString IO b -> CreateProcess -> IO (ByteString, ByteString, ExitCode)
capture sout serr =
  let cap x = C.passthroughSink x (const . pure $ ()) =$= CL.foldMap id
   in raw (cap sout) (cap serr)

withEnv :: [WithEnv] -> CreateProcess -> IO CreateProcess
withEnv es cp = do
  envs <- getEnvironment
  pure $ cp { env = Just $ catMaybes . flip fmap es $ \e -> case e of
    InheritEnv k ->
      find ((==) (T.unpack k) . fst) envs
    SetEnv k v ->
      Just (T.unpack k, T.unpack v) }

exec :: Sink ByteString IO a -> Sink ByteString IO b -> CreateProcess -> IO ExitCode
exec cout cerr cp =
  (\(_, _, e) -> e) <$> raw cout cerr cp

raw :: Sink ByteString IO a -> Sink ByteString IO b -> CreateProcess -> IO (a, b, ExitCode)
raw cout cerr cp = do
  (CP.ClosedStream, sout, serr, handle) <- CP.streamingProcess cp
  runConcurrently $
    (,,)
      <$> Concurrently (sout $$ cout)
      <*> Concurrently (serr $$ cerr)
      <*> Concurrently (CP.waitForStreamingProcess handle)


execOrTerminateOnPin :: Pin -> Sink ByteString IO () -> Sink ByteString IO () -> CreateProcess -> IO StreamingProcessOrPin
execOrTerminateOnPin pin cout cerr cp = do
  (CP.ClosedStream, sout, serr, handle) <- CP.streamingProcess cp

  execing <- async . runConcurrently $
    (,,)
      <$> Concurrently (sout $$ cout)
      <*> Concurrently (serr $$ cerr)
      <*> Concurrently (CP.waitForStreamingProcess handle)

  checking <- async $ waitForPin pin

  waitEither checking execing >>= \x -> case x of
    Left _ ->
      StreamingPinPulled <$> terminate (CP.streamingProcessHandleRaw handle) <* cancel execing
    Right (_, _, code) ->
      StreamingProcessStopped code <$ cancel checking


xproc :: Out -> Text -> [Text] -> IO CreateProcess
xproc out cmd args = do
  xPutStrLn out $ T.intercalate " " $ mconcat [[">", cmd], fmap (\arg -> mconcat ["\"", arg, "\""]) args]
  pure $ proc (T.unpack cmd) (fmap T.unpack args)

xprocAt :: Out -> FilePath -> Text -> [Text] -> IO CreateProcess
xprocAt out dir cmd args =
  inDirectory dir <$> xproc out cmd args

inDirectory :: FilePath -> CreateProcess -> CreateProcess
inDirectory dir p =
  p { cwd = Just dir }

hoistExit :: (Applicative f, Monad f) => ExitCode -> EitherT ExitCode f ()
hoistExit c =
  case c of
    ExitSuccess ->
      pure ()
    ExitFailure _ ->
      left c

hoistExitM :: (Applicative f, Monad f) => f ExitCode -> EitherT ExitCode f ()
hoistExitM e =
  lift e >>= hoistExit
