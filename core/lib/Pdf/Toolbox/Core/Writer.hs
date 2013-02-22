{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Write PDF files
--
-- It could be used to generate new PDF file
-- or to incrementally update the existent one
--
-- To generate new file, first call 'writePdfHeader',
-- then a number of 'writeObject' and finally 'writeXRefTable'
--
-- To incrementally update PDF file just ommit the
-- `writePdfHeader` and append the result to the existent file

module Pdf.Toolbox.Core.Writer
(
  PdfWriter,
  runPdfWriter,
  writePdfHeader,
  writeObject,
  writeXRefTable
)
where

import Data.Int
import Data.Set (Set)
import qualified Data.Set as Set
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Lazy.Builder
import Data.ByteString.Lazy.Builder.ASCII
import Data.Function
import Data.Monoid
import Control.Monad
import Control.Monad.Trans.Class
import Control.Monad.Trans.State
import Control.Monad.IO.Class
import System.IO.Streams (OutputStream)
import qualified System.IO.Streams as Streams

import Pdf.Toolbox.Core.Object.Types
import Pdf.Toolbox.Core.Object.Builder

-- | The monad
newtype PdfWriter m a = PdfWriter (StateT PdfState m a)
  deriving (Monad, MonadIO, MonadTrans)

-- | Execute writer action
runPdfWriter :: MonadIO m
             => OutputStream ByteString    -- ^ streams to write to
             -> PdfWriter m a              -- ^ action to run
             -> m a
runPdfWriter output (PdfWriter action) = do
  (out, count) <- liftIO $ Streams.countOutput output
  let emptyState = PdfState {
        stOutput = out,
        stObjects = Set.empty,
        stCount = count,
        stOffset = 0
        }
  evalStateT action emptyState

data Elem = Elem {
  elemIndex :: Int,
  elemGen :: Int,
  elemOffset :: Int64,
  elemFree :: Bool
  }

instance Eq Elem where
  (==) = (==) `on` elemIndex

instance Ord Elem where
  compare = compare `on` elemIndex

data PdfState = PdfState {
  stOutput :: OutputStream ByteString,
  stObjects :: Set Elem,
  stCount :: IO Int64,
  stOffset :: Int64
  }

-- | Write PDF header. Used for generating new PDF files.
-- Should be the first call. Not used fo incremental updates
writePdfHeader :: MonadIO m => PdfWriter m ()
writePdfHeader = do
  output <- PdfWriter $ gets stOutput
  liftIO $ Streams.write (Just "%PDF-1.7\n") output

-- | Write object
writeObject :: MonadIO m => Ref -> Object BSL.ByteString -> PdfWriter m ()
writeObject ref@(Ref index gen) obj = do
  st <- PdfWriter get
  pos <- countWritten
  addElem $ Elem index gen pos False
  dumpObject (stOutput st) ref obj
  return ()

-- | Write xref table. Should be the last call.
-- Used for generating and incremental updates.
writeXRefTable :: MonadIO m
               => Int64           -- ^ size of the original PDF file. Should be 0 for new file
               -> Dict            -- ^ trailer
               -> PdfWriter m ()
writeXRefTable offset tr = do
  st <- PdfWriter get
  off <- (+ offset) `liftM` countWritten
  let elems = Set.map (\e -> e {elemOffset = elemOffset e + offset})  $ stObjects st
      content = buildXRefTable (Set.toAscList elems) `mappend`
                byteString "trailer\n" `mappend`
                buildDict tr `mappend`
                byteString "\nstartxref\n" `mappend`
                int64Dec off `mappend`
                byteString "\n%%EOF\n"
  liftIO $ Streams.writeLazyByteString (toLazyByteString content) (stOutput st)

countWritten :: MonadIO m => PdfWriter m Int64
countWritten = do
  st <- PdfWriter get
  c <- liftIO $ stCount st
  PdfWriter $ put $ st {stOffset = stOffset st + c}
  return $ stOffset st + c

addElem :: Monad m => Elem -> PdfWriter m ()
addElem e = PdfWriter $ modify $ \st -> st {stObjects = Set.insert e (stObjects st)}

dumpObject :: MonadIO m => OutputStream ByteString -> Ref -> Object BSL.ByteString -> m ()
dumpObject out ref o = liftIO $ Streams.writeLazyByteString (toLazyByteString $ buildIndirectObject ref o) out

buildXRefTable :: [Elem] -> Builder
buildXRefTable entries =
  string7 "xref\n" `mappend`
  mconcat (map buildXRefSection $ sections entries)
  where
  sections :: [Elem] -> [[Elem]]
  sections [] = []
  sections xs = let (s, rest) = section xs in s : sections rest
  section [] = error "impossible"
  section (x:xs) = go (elemIndex x + 1) [x] xs
    where
    go _ res [] = (reverse res, [])
    go i res (y:ys) =
      if i == elemIndex y
        then go (i + 1) (y : res) ys
        else (reverse res, y:ys)

buildXRefSection :: [Elem] -> Builder
buildXRefSection [] = error "impossible"
buildXRefSection s@(e:_) =
  intDec (elemIndex e) `mappend`
  char7 ' ' `mappend`
  intDec (length s) `mappend`
  char7 '\n' `mappend`
  loop s
  where
  loop (x:xs) =
    buildFixed 10 '0' (elemOffset x) `mappend`
    char7 ' ' `mappend`
    buildFixed 5 '0' (elemGen x) `mappend`
    char7 ' ' `mappend`
    char7 (if elemFree x then 'f' else 'n') `mappend`
    string7 "\r\n" `mappend`
    loop xs
  loop [] = mempty

buildFixed :: Show a => Int -> Char -> a -> Builder
buildFixed len c i =
  let v = take len $ show i
      l = length v
  in string7 $ replicate (len - l) c ++ v
