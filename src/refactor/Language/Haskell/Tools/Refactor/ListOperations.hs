{-# LANGUAGE TupleSections #-}
-- | Defines operation on AST lists.
-- AST lists carry source information so simple list modification is not enough.
module Language.Haskell.Tools.Refactor.ListOperations where

import Control.Reference
import Data.List (findIndices)

import Language.Haskell.Tools.AST
import Language.Haskell.Tools.AST.Rewrite (AnnList)
import Language.Haskell.Tools.Transform (srcTmpDefaultSeparator, srcTmpSeparators, srcTmpIndented)

-- | Filters the elements of the list. By default it removes the separator before the element.
-- Of course, if the first element is removed, the following separator is removed as well.
filterList :: (Ann e dom SrcTemplateStage -> Bool) -> AnnList e dom -> AnnList e dom
filterList pred = filterListIndexed (const pred)

filterListIndexed :: (Int -> Ann e dom SrcTemplateStage -> Bool) -> AnnList e dom -> AnnList e dom
filterListIndexed pred (AnnListG (NodeInfo sema src) elems)
  = AnnListG (NodeInfo sema (srcTmpIndented .- fmap filterIndents $ srcTmpSeparators .- filterSeparators $ src)) filteredElems
  where elementsKept = findIndices (uncurry pred) (zip [0..] elems)
        filteredElems = sublist elementsKept elems
        filterIndents = sublist elementsKept
        filterSeparators = take (length elementsKept - 1) . sublist elementsKept

-- | Selects the given indices from a list
sublist :: [Int] -> [a] -> [a]
sublist = sublist' 0
  where sublist' i [] _ = []
        sublist' i _ [] = []
        sublist' i (ind:more) (e:rest)
          | i == ind  = e : sublist' (i+1) more rest
          | otherwise = sublist' (i+1) (ind:more) rest

-- | Inserts the element in the places where the two positioning functions (one checks the element before, one the element after)
-- allows the placement.
insertWhere :: Bool -> Ann e dom SrcTemplateStage -> (Maybe (Ann e dom SrcTemplateStage) -> Bool)
                 -> (Maybe (Ann e dom SrcTemplateStage) -> Bool) -> AnnList e dom
                 -> AnnList e dom
insertWhere indented e before after al
  = let index = insertIndex before after (al ^? annList)
     in case index of
          Nothing -> al
          Just ind -> annListElems .- insertAt ind e
                        $ (if isEmptyAnnList then id else annListAnnot&sourceInfo .- setIndented ind . addDefaultSeparator ind)
                        $ al
  where setIndented i = srcTmpIndented .- fmap (insertAt i indented)
        addDefaultSeparator i al = srcTmpSeparators .- insertAt i (al ^. srcTmpDefaultSeparator) $ al
        insertAt n e ls = let (bef,aft) = splitAt n ls in bef ++ [e] ++ aft
        isEmptyAnnList = (null :: [x] -> Bool) $ (al ^? annList)

-- | Checks where the element will be inserted given the two positioning functions.
insertIndex :: (Maybe (Ann e dom SrcTemplateStage) -> Bool) -> (Maybe (Ann e dom SrcTemplateStage) -> Bool) -> [Ann e dom SrcTemplateStage] -> Maybe Int
insertIndex before after []
  | before Nothing && after Nothing = Just 0
  | otherwise = Nothing
insertIndex before after list@(first:_)
  | before Nothing && after (Just first) = Just 0
  | otherwise = (+1) <$> insertIndex' before after list
  where insertIndex' before after (curr:rest@(next:_))
          | before (Just curr) && after (Just next) = Just 0
          | otherwise = (+1) <$> insertIndex' before after rest
        insertIndex' before after (curr:[])
          | before (Just curr) && after Nothing = Just 0
          | otherwise = Nothing
        insertIndex' before after []
          | before Nothing && after Nothing = Just 0
          | otherwise = Nothing

-- | Gets the elements and separators from a list. The first separator is zipped to the second element.
-- To the first element, the "" string is zipped.
zipWithSeparators :: AnnList e dom -> [(String, Ann e dom SrcTemplateStage)]
zipWithSeparators (AnnListG (NodeInfo _ src) elems)
  | [] <- src ^. srcTmpSeparators
  = zip ("" : repeat (src ^. srcTmpDefaultSeparator)) elems
  | otherwise
  = zip ("" : seps ++ repeat (last seps)) elems
  where seps = src ^. srcTmpSeparators
