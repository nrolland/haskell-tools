{-# LANGUAGE LambdaCase #-}
module Language.Haskell.Tools.AST.FromGHC.Decl where

import RdrName as GHC
import Class as GHC
import HsSyn as GHC
import SrcLoc as GHC
import HsDecls as GHC
import Name as GHC
import OccName as GHC
import ApiAnnotation as GHC
import FastString as GHC
import BasicTypes as GHC
import Bag as GHC

import Language.Haskell.Tools.AST.Ann
import qualified Language.Haskell.Tools.AST.Base as AST
import qualified Language.Haskell.Tools.AST.Decl as AST
import Language.Haskell.Tools.AST.FromGHC.Base
import Language.Haskell.Tools.AST.FromGHC.Monad
import Language.Haskell.Tools.AST.FromGHC.Utils

trfDecls :: [LHsDecl RdrName] -> Trf (AnnList AST.Decl RI)
trfDecls decls = AnnList <$> mapM trfDecl decls

trfDecl :: Located (HsDecl RdrName) -> Trf (Ann AST.Decl RI)
trfDecl = trfLoc $ \case
  TyClD (FamDecl (FamilyDecl DataFamily name tyVars kindSig)) 
    -> AST.DataFamilyDecl <$> createDeclHead name tyVars <*> trfKindSig kindSig
  TyClD (FamDecl (FamilyDecl OpenTypeFamily name tyVars kindSig)) 
    -> AST.TypeFamilyDecl <$> createDeclHead name tyVars <*> trfKindSig kindSig
  TyClD (FamDecl (FamilyDecl (ClosedTypeFamily typeEqs) name tyVars kindSig)) 
    -> AST.ClosedTypeFamilyDecl <$> createDeclHead name tyVars <*> trfKindSig kindSig <*> trfTypeEqs typeEqs
  TyClD (SynDecl name vars rhs _) 
    -> AST.TypeDecl <$> createDeclHead name vars <*> trfType rhs
  -- TyClD (DataDecl name vars (HsDataDefn nd ctx ct kind cons derivs) _) 
    -- -> AST.DataDecl 
  -- TyClD (ClassDecl ctx name vars funDeps sigs defs typeFuns typeFunDefs docs _) 
    -- -> AST.ClassDecl <$> trfCtx ctx <*> createDeclHead name vars <*> trfFunDeps funDeps 
                     -- <*> createClassBody sigs defs typeFuns typeFunDefs
  -- InstD inst = 
  ValD bind -> AST.ValueBinding <$> trfBind' bind
  -- SigD sig =
  -- DefD def =
  -- ForD for =
  -- WarningD warn =
  -- AnnD ann =
  -- RuleD rule =
  -- VecD vec =
  -- SpliceD splice =
  -- DocD doc
  -- QuasiQuoteD qq =
  -- RoleAnnotD role =  

trfBind :: Located (HsBind RdrName) -> Trf (Ann AST.ValueBind RI)
trfBind = trfLoc trfBind'
  
trfBind' :: HsBind RdrName -> Trf (AST.ValueBind RI)
trfBind' (FunBind { fun_id = id, fun_matches = MG { mg_alts = [L matchLoc (Match { m_pats = [], m_grhss = GRHSs [L rhsLoc (GRHS [] expr)] locals })]} }) = AST.SimpleBind <$> (takeAnnot AST.VarPat (trfName id)) <*> annLoc (combineSrcSpans (getLoc expr) <$> tokenLoc AnnEqual) (AST.UnguardedRhs <$> trfExpr expr) <*> trfWhereLocalBinds locals
trfBind' (FunBind id isInfix (MG matches _ _ _) _ _ _) = AST.FunBind . AnnList <$> mapM (trfMatch id) matches
trfBind' (PatBind pat (GRHSs rhs locals) _ _ _) = AST.SimpleBind <$> trfPattern pat <*> trfRhss rhs <*> trfWhereLocalBinds locals
trfBind' (AbsBinds typeVars vars exports _ _) = undefined
trfBind' (PatSynBind psb) = undefined
  
trfMatch :: Located RdrName -> Located (Match RdrName (LHsExpr RdrName)) -> Trf (Ann AST.Match RI)
trfMatch name = trfLoc $ \(Match funid pats typ (GRHSs rhss locBinds))
  -> AST.Match <$> trfName (maybe name fst funid) <*> (AnnList <$> mapM trfPattern pats) <*> trfMaybe trfType typ 
               <*> trfRhss rhss <*> trfWhereLocalBinds locBinds
  
trfRhss :: [Located (GRHS RdrName (LHsExpr RdrName))] -> Trf (Ann AST.Rhs RI)
trfRhss [L l (GRHS [] body)] = annLoc (pure l) (AST.UnguardedRhs <$> trfExpr body)
trfRhss rhss = annLoc (pure $ collectLocs rhss) 
                      (AST.GuardedRhss . AnnList <$> mapM trfGuardedRhs rhss)
  
trfGuardedRhs :: Located (GRHS RdrName (LHsExpr RdrName)) -> Trf (Ann AST.GuardedRhs RI)
trfGuardedRhs = trfLoc $ \(GRHS guards body) 
  -> AST.GuardedRhs . AnnList <$> mapM trfRhsGuard guards <*> trfExpr body
  
trfRhsGuard :: Located (Stmt RdrName (LHsExpr RdrName)) -> Trf (Ann AST.RhsGuard RI)
trfRhsGuard = trfLoc $ \case
  BindStmt pat body _ _ -> AST.GuardBind <$> trfPattern pat <*> trfExpr body
  BodyStmt body _ _ _ -> AST.GuardCheck <$> trfExpr body
  LetStmt binds -> AST.GuardLet <$> trfLocalBinds binds
  
trfWhereLocalBinds :: HsLocalBinds RdrName -> Trf (AnnMaybe AST.LocalBinds RI)
trfWhereLocalBinds EmptyLocalBinds = pure annNothing  
trfWhereLocalBinds binds@(HsValBinds (ValBindsIn vals sigs)) 
  = annJust <$> annLoc (collectAnnots . fromAnnList <$> localBinds) (AST.LocalBinds <$> localBinds)
      where localBinds = trfLocalBinds binds


trfLocalBinds :: HsLocalBinds RdrName -> Trf (AnnList AST.LocalBind RI)
trfLocalBinds (HsValBinds (ValBindsIn binds sigs)) 
  = AnnList . orderDefs <$> ((++) <$> mapM (takeAnnot AST.LocalValBind . trfBind) (bagToList binds) 
                                  <*> mapM trfLocalSig sigs)

trfLocalSig :: Located (Sig RdrName) -> Trf (Ann AST.LocalBind RI)
trfLocalSig = trfLoc $ \case
  ts@(TypeSig {}) -> AST.LocalSignature <$> trfTypeSig ts
  (FixSig fs) -> AST.LocalFixity <$> trfFixitySig fs
  
trfTypeSig :: Sig RdrName -> Trf (AST.TypeSignature RI)
trfTypeSig (TypeSig [name] typ _) = AST.TypeSignature <$> trfName name <*> trfType typ
  
trfFixitySig :: FixitySig RdrName -> Trf (AST.FixitySignature RI)
trfFixitySig (FixitySig names (Fixity prec dir)) 
  = AST.FixitySignature <$> transformDir dir
                        <*> annLoc (tokenLoc AnnVal) (pure $ AST.Precedence prec) 
                        <*> (AnnList <$> mapM trfName names)
  where transformDir InfixL = directionChar (pure AST.AssocLeft)
        transformDir InfixR = directionChar (pure AST.AssocRight)
        transformDir InfixN = annLoc (srcLocSpan . srcSpanEnd <$> tokenLoc AnnInfix) (pure AST.AssocNone)
        
        directionChar = annLoc ((\l -> mkSrcSpan (moveBackOneCol l) l) . srcSpanEnd <$> tokenLoc AnnInfix)
        moveBackOneCol (RealSrcLoc rl) = mkSrcLoc (srcLocFile rl) (srcLocLine rl) (srcLocCol rl - 1)
        moveBackOneCol (UnhelpfulLoc fs) = UnhelpfulLoc fs
        
trfPattern :: Located (Pat RdrName) -> Trf (Ann AST.Pattern RI)
trfPattern = undefined

trfExpr :: Located (HsExpr RdrName) -> Trf (Ann AST.Expr RI)
trfExpr = undefined
  
trfKindSig :: Maybe (LHsKind RdrName) -> Trf (AnnMaybe AST.KindConstraint RI)
trfKindSig = trfMaybe (\k -> annLoc (combineSrcSpans (getLoc k) <$> (tokenLoc AnnDcolon)) 
                                    (fmap AST.KindConstraint $ trfLoc trfKind' k))

trfKind :: Located (HsKind RdrName) -> Trf (Ann AST.Kind RI)
trfKind = trfLoc trfKind'

trfKind' :: HsKind RdrName -> Trf (AST.Kind RI)
trfKind' (HsTyVar (Exact n)) 
  | isWiredInName n && occNameString (nameOccName n) == "*"
  = pure AST.KindStar
  | isWiredInName n && occNameString (nameOccName n) == "#"
  = pure AST.KindUnbox
trfKind' (HsParTy kind) = AST.KindParen <$> trfKind kind
trfKind' (HsFunTy k1 k2) = AST.KindFn <$> trfKind k1 <*> trfKind k2
trfKind' (HsAppTy k1 k2) = AST.KindApp <$> trfKind k1 <*> trfKind k2
trfKind' (HsTyVar kv) = AST.KindVar <$> trfName' kv
trfKind' (HsExplicitTupleTy _ kinds) = AST.KindTuple . AnnList <$> mapM trfKind kinds
trfKind' (HsExplicitListTy _ kinds) = AST.KindList . AnnList <$> mapM trfKind kinds
  
trfTypeEqs :: [Located (TyFamInstEqn RdrName)] -> Trf (AnnList AST.TypeEqn RI)
trfTypeEqs = fmap AnnList . mapM trfTypeEq

trfTypeEq :: Located (TyFamInstEqn RdrName) -> Trf (Ann AST.TypeEqn RI)
trfTypeEq = trfLoc $ \(TyFamEqn name pats rhs) 
  -> AST.TypeEqn <$> combineTypes name pats <*> trfType rhs
  where combineTypes :: Located RdrName -> HsTyPats RdrName -> Trf (Ann AST.Type RI)
        combineTypes name pats 
          = foldl (\t p -> do typ <- t
                              annLoc (pure $ combineSrcSpans (annotation typ) (getLoc p)) 
                                     (AST.TyApp <$> pure typ <*> trfType p)) 
                  (annLoc (pure $ getLoc name) (AST.TyCon <$> trfName' (unLoc name))) 
                  (hswb_cts pats)
                 
  
trfType :: Located (HsType RdrName) -> Trf (Ann AST.Type RI)
trfType = trfLoc trfType'

trfType' :: HsType RdrName -> Trf (AST.Type RI)
trfType' (HsForAllTy _ _ bndrs ctx typ) = AST.TyForall <$> trfBindings (hsq_tvs bndrs) 
                                                       <*> trfCtx ctx <*> trfType typ
trfType' (HsTyVar name) | isRdrTc name = AST.TyCon <$> trfName' name
trfType' (HsTyVar name) | isRdrTyVar name = AST.TyVar <$> trfName' name
trfType' (HsAppTy t1 t2) = AST.TyApp <$> trfType t1 <*> trfType t2
trfType' (HsFunTy t1 t2) = AST.TyFun <$> trfType t1 <*> trfType t2
trfType' (HsListTy typ) = AST.TyList <$> trfType typ
trfType' (HsPArrTy typ) = AST.TyParArray <$> trfType typ
-- HsBoxedOrConstraintTuple?
trfType' (HsTupleTy HsBoxedTuple typs) = AST.TyTuple . AnnList <$> mapM trfType typs
trfType' (HsTupleTy HsUnboxedTuple typs) = AST.TyUnbTuple . AnnList <$> mapM trfType typs
trfType' (HsOpTy t1 op t2) = AST.TyInfix <$> trfType t1 <*> trfName (snd op) <*> trfType t2
trfType' (HsParTy typ) = AST.TyParen <$> trfType typ
trfType' (HsKindSig typ kind) = AST.TyKinded <$> trfType typ <*> trfKind kind
trfType' (HsQuasiQuoteTy qq) = AST.TyQuasiQuote <$> trfQuasiQuotation' qq
trfType' (HsSpliceTy splice _) = AST.TySplice <$> trfSplice' splice
trfType' (HsBangTy _ typ) = AST.TyBang <$> trfType typ
-- HsRecTy
-- HsCoreTy
trfType' (HsTyLit (HsNumTy _ int)) = pure $ AST.TyNumLit int
trfType' (HsTyLit (HsStrTy _ str)) = pure $ AST.TyStrLit (unpackFS str)
trfType' (HsWrapTy _ typ) = trfType' typ
trfType' HsWildcardTy = pure AST.TyWildcard
-- not implemented as ghc 7.10.3
trfType' (HsNamedWildcardTy name) = AST.TyNamedWildcard <$> trfName' name


  
trfBindings :: [Located (HsTyVarBndr RdrName)] -> Trf (AnnList AST.TyVar RI)
trfBindings = undefined
  
trfCtx :: Located (HsContext RdrName) -> Trf (AnnMaybe AST.Context RI)
trfCtx (L l []) = pure annNothing
trfCtx (L l [L _ (HsParTy t)]) 
  = annJust <$> annLoc (combineSrcSpans l <$> tokenLoc AnnDarrow) 
                       (AST.ContextMulti . AnnList . (:[]) <$> trfAssertion t)
trfCtx (L l [L _ t]) 
  = annJust <$> annLoc (combineSrcSpans l <$> tokenLoc AnnDarrow) 
                       (AST.ContextOne <$> trfAssertion' t)
trfCtx (L l ctx) = annJust <$> annLoc (combineSrcSpans l <$> tokenLoc AnnDarrow) 
                                      (AST.ContextMulti . AnnList <$> mapM trfAssertion ctx) 
  
  
trfAssertion :: Located (HsType RdrName) -> Trf (Ann AST.Assertion RI)
trfAssertion = trfLoc trfAssertion'

trfAssertion' :: HsType RdrName -> Trf (AST.Assertion RI)
trfAssertion' = undefined
-- trfAssertion' (HsIParamTy typ) = _
-- trfAssertion' (HsEqTy t1 t2) = _
  
trfFunDeps :: [Located (FunDep (Located name))] -> Trf (AnnMaybe AST.FunDeps RI)
trfFunDeps [] = pure annNothing
trfFunDeps _ = pure undefined
  
createDeclHead :: Located RdrName -> LHsTyVarBndrs RdrName -> Trf (Ann AST.DeclHead RI)
createDeclHead name vars
  = foldl (\t p -> do typ <- t
                      annLoc (pure $ combineSrcSpans (annotation typ) (getLoc p)) 
                             (AST.DHApp typ <$> trfTyVar p)) 
          (annLoc (pure $ getLoc name) (AST.DeclHead <$> trfName' (unLoc name))) 
          (hsq_tvs vars)
          
-- createClassBody :: [LSig RdrName] -> LHsBinds RdrName -> [LFamilyDecl RdrName] 
                               -- -> [LTyFamDefltEqn RdrName] -> Trf (AnnMaybe AST.ClassBody RI)
-- createClassBody sigs binds typeFams typeFamDefs 
  -- = do isThereWhere <- not . isGoodSrcSpan <$> (tokenLoc AnnWhere)
       -- if isThereWhere 
         -- then annJust . annLoc (combinedLoc <$> tokenLoc AnnWhere) 
                               -- (AST.ClassBody <$> )
         -- else pure annNothing
  -- where combinedLoc wh = foldl combineSrcSpan wh allLocs
        -- allLocs = map getLoc sigs ++ map getLoc (toList binds) ++ map getLoc typeFams ++ map getLoc typeFamDefs
        -- getSigs = mapM trfClassElemSig sigs
        -- getBinds = mapM trfClassElemSig (toList binds)
        -- getFams = mapM trfClassElemSig typeFams
        -- getFamDefs = mapM trfClassElemSig typeFamDefs
       
-- trfClassElemSig :: Located (Sig RdrName) -> Trf (Ann AST.ClassElement RI)
-- trfClassElemSig = trfLoc $ \case
  -- TypeSig [name] typ _ -> AST.ClsSig <$> trfName name <*> trfType typ
  -- GenericSig [name] typ _ -> AST.ClsDefSig <$> trfName name <*> trfType typ
         
trfTyVar :: Located (HsTyVarBndr RdrName) -> Trf (Ann AST.TyVar RI)
trfTyVar var@(L l _) = trfLoc (\case
  UserTyVar name -> AST.TyVarDecl <$> annLoc (pure l) (trfName' name) <*> pure annNothing
  KindedTyVar name kind -> AST.TyVarDecl <$> trfName name <*> trfKindSig (Just kind)) var
          
trfQuasiQuotation' :: HsQuasiQuote RdrName -> Trf (AST.QuasiQuote RI)
trfQuasiQuotation' = undefined

trfSplice' :: HsSplice RdrName -> Trf (AST.Splice RI)
trfSplice' = undefined
  