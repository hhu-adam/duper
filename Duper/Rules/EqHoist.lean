import Duper.MClause
import Duper.RuleM
import Duper.Simp
import Duper.Util.ProofReconstruction

namespace Duper
open Lean
open RuleM
open SimpResult

initialize Lean.registerTraceClass `Rule.eqHoist

theorem eq_hoist_proof (x y : α) (f : Prop → Prop) (h : f (x = y)) : f False ∨ x = y := by
  by_cases x_eq_y : x = y
  . exact Or.inr x_eq_y
  . rename ¬x = y => x_ne_y
    have x_eq_y_false := eq_false x_ne_y
    exact Or.inl $ x_eq_y_false ▸ h

def mkEqHoistProof (pos : ClausePos) (freshVar1 freshVar2 : Expr) (premises : List Expr)
  (parents : List ProofParent) (c : Clause) : MetaM Expr :=
  Meta.forallTelescope c.toForallExpr fun xs body => do
    let cLits := c.lits.map (fun l => l.map (fun e => e.instantiateRev xs))
    let (parentsLits, appliedPremises) ← instantiatePremises parents premises xs
    let parentLits := parentsLits[0]!
    let appliedPremise := appliedPremises[0]!

    let mut caseProofs := Array.mkEmpty parentLits.size
    for i in [:parentLits.size] do
      let lit := parentLits[i]!
      let pr : Expr ← Meta.withLocalDeclD `h lit.toExpr fun h => do
        if i == pos.lit then
          let substLitPos : LitPos := ⟨pos.side, pos.pos⟩
          let abstrLit ← (lit.abstractAtPos! substLitPos)
          let abstrExp := abstrLit.toExpr
          let abstrLam := mkLambda `x BinderInfo.default (mkSort levelZero) abstrExp
          let lastTwoClausesProof ← Meta.mkAppM ``eq_hoist_proof #[freshVar1, freshVar2, abstrLam, h]
          Meta.mkLambdaFVars #[h] $ ← orSubclause (cLits.map Lit.toExpr) 2 lastTwoClausesProof
        else
          let idx := if i ≥ pos.lit then i - 1 else i
          Meta.mkLambdaFVars #[h] $ ← orIntro (cLits.map Lit.toExpr) idx h
      caseProofs := caseProofs.push pr
    let r ← orCases (parentLits.map Lit.toExpr) caseProofs
    Meta.mkLambdaFVars xs $ mkApp r appliedPremise

def eqHoistAtExpr (e : Expr) (pos : ClausePos) (c : MClause) : RuleM Unit :=
  withoutModifyingMCtx do
    let lit := c.lits[pos.lit]!
    if e.getTopSymbol.isMVar then -- Check condition 4
      -- If the head of e is a variable then it must be applied and the affected literal must be either
      -- e = True, e = False, or e = e' where e' is another variable headed term
      if not e.isApp then -- e is a non-applied variable and so we cannot apply eqHoist
        return
      if pos.pos != #[] then
        return -- e is not at the top level so the affected literal cannot have the form e = ...
      if not lit.sign then
        return -- The affected literal is not positive and so it cannot have the form e = ...
      let otherSide := lit.getOtherSide pos.side
      if otherSide != (mkConst ``True) && otherSide != (mkConst ``False) && not otherSide.getTopSymbol.isMVar then
        return -- The other side is not True, False, or variable headed, so the affected literal cannot have the required form
    -- Check conditions 1 and 3 (condition 2 is guaranteed by construction)
    let eligibility ← eligibilityPreUnificationCheck c pos.lit
    if eligibility == Eligibility.notEligible then
      return
    -- The way we make freshVar1, freshVar2, and freshVarEquality depends on whether e itself is an equality
    let mkFreshVarsAndEquality (e : Expr) : RuleM (Expr × Expr × Expr) :=
      match e with
      | Expr.app (Expr.app (Expr.app (Expr.const ``Eq lvls) ty) _) _ => do
        -- If e is an equality, then we can directly read the correct lvls and ty
        let freshVar1 ← mkFreshExprMVar ty
        let freshVar2 ← mkFreshExprMVar ty
        return (freshVar1, freshVar2, mkApp3 (mkConst ``Eq lvls) ty freshVar1 freshVar2)
      | _ => do
        -- If e is not an equality, the best we can do is generate an arbitrary equality and leave the rest to unification
        let freshVar1 ← mkFreshExprMVar none
        let freshVarTy ← inferType freshVar1 
        let freshVar2 ← mkFreshExprMVar freshVarTy
        return (freshVar1, freshVar2, ← mkAppM ``Eq #[freshVar1, freshVar2])
    let (freshVar1, freshVar2, freshVarEquality) ← mkFreshVarsAndEquality e 
    if not $ ← unify #[(e, freshVarEquality)] then
      return -- Unification failed, so eqHoist cannot occur
    if not $ ← eligibilityPostUnificationCheck c pos.lit eligibility (strict := lit.sign) then
      return
    let eSide ← RuleM.instantiateMVars $ lit.getSide pos.side
    let otherSide ← RuleM.instantiateMVars $ lit.getOtherSide pos.side
    let cmp ← compare eSide otherSide
    if cmp == Comparison.LessThan || cmp == Comparison.Equal then -- If eSide ≤ otherSide then e is not in an eligible position
      return
    -- All side conditions have been met. Yield the appropriate clause
    let cErased := c.eraseLit pos.lit
    -- Need to instantiate mvars in freshVar1, freshVar2, and freshVarEquality because unification assigned to mvars in each of them
    let freshVar1 ← RuleM.instantiateMVars freshVar1
    let freshVar2 ← RuleM.instantiateMVars freshVar2
    let freshVarEquality ← RuleM.instantiateMVars freshVarEquality 
    let newClause := cErased.appendLits #[← lit.replaceAtPos! ⟨pos.side, pos.pos⟩ (mkConst ``False), Lit.fromExpr freshVarEquality]
    trace[Rule.eqHoist] "Created {newClause.lits} from {c.lits}"
    yieldClause newClause "eqHoist" $ some (mkEqHoistProof pos freshVar1 freshVar2)

def eqHoist (c : MClause) (cNum : Nat) : RuleM Unit := do
  let fold_fn := fun () e pos => eqHoistAtExpr e.consumeMData pos c
  c.foldGreenM fold_fn ()