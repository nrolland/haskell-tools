{-# LANGUAGE LambdaCase #-}
module Language.Haskell.Tools.AnnTrf.RangeToSource where

import SrcLoc
import StringBuffer
import Data.StructuralTraversal
import Data.Map
import Data.Monoid
import Control.Monad.State
import Language.Haskell.Tools.AST.Ann
import Language.Haskell.Tools.AST.FromGHC.OrdSrcSpan
import Language.Haskell.Tools.AnnTrf.RangeToTemplate
import Language.Haskell.Tools.AnnTrf.SourceTemplate

rangeToSource :: StructuralTraversable node => StringBuffer -> Ann node RangeTemplate -> Ann node SourceTemplate
rangeToSource srcInput tree = let locIndices = getLocIndices tree
                                  srcMap = mapLocIndices srcInput locIndices
                               in applyFragments (elems srcMap) tree

-- maps could be strict

getLocIndices :: StructuralTraversable e => Ann e RangeTemplate -> Map OrdSrcSpan Int
getLocIndices = snd . flip execState (0, empty) .
  traverseDown (return ()) 
               (return ()) 
               (mapM_ (\case (RangeElem sp) -> modify (\(i,m) -> (i+1, insert (OrdSrcSpan sp) i m))
                             _              -> return ()) . rangeTemplateElems)

mapLocIndices :: Ord k => StringBuffer -> Map OrdSrcSpan k -> Map k String
mapLocIndices inp = fst . foldlWithKey (\(new, str) sp k -> let (rem, val) = takeSpan str sp
                                                             in (insert k (reverse val) new, rem)) (empty, inp)
  where takeSpan :: StringBuffer -> OrdSrcSpan -> (StringBuffer, String)
        takeSpan str (OrdSrcSpan sp) = takeSpan' (realSrcSpanStart sp) (realSrcSpanEnd sp) (str,"")

        takeSpan' :: RealSrcLoc -> RealSrcLoc -> (StringBuffer, String) -> (StringBuffer, String)
        takeSpan' start end (sb, taken) | start < end && not (atEnd sb)
          = let (c,rem) = nextChar sb in takeSpan' (advanceSrcLoc start c) end (rem, c:taken)
        takeSpan' _ _ (rem, taken) = (rem, taken)
        
applyFragments :: StructuralTraversable node => [String] -> Ann node RangeTemplate -> Ann node SourceTemplate
applyFragments srcs = flip evalState srcs
  . traverseDown (return ()) (return ())
                 (mapM (\case RangeElem sp     -> do (src:rest) <- get
                                                     put rest
                                                     return (TextElem src)
                              RangeChildElem i -> return $ ChildElem i) . rangeTemplateElems)