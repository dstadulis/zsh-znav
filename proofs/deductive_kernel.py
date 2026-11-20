#!/usr/bin/env python3
r"""LCF-Style Deductive Symbolic Proof Kernel & Certificate Verifier for znav.

Proves the symbolic transcendental, inductive, and order-isomorphism theorems
of Primitive 1 directly on syntax trees (without change-of-variables shortcuts
or unproved `sorry` assumptions), and exports a machine-checkable step-by-step
proof certificate (`deductive_certificates.json`) verified by an independent
certificate replay checker.

Verified Theorems:
  - Theorem 1a-Step:
      tau > 0 |- exp((lse(lam, tm1, tau) - t) / tau)
                 = exp((lam - t) / tau) + exp(-(t - tm1) / tau)
      (proved by exhaustive case split on lam >= tm1 vs lam < tm1, covering
      arbitrary non-monotonic clock jitter!)
  - Theorem 1a-Induction:
      tau > 0 |- forall m >= 1:
                 exp((Lambda^(m) - t) / tau) = Sum_{k=1..m} exp(-(t - t_k) / tau)
      (proved by Peano / natural-number induction on visit count m >= 1!)
  - Theorem 1b-OrderInvariance:
      tau > 0 |- (exp((la - t1)/tau) > exp((lb - t1)/tau) <=> la > lb)
              /\ (la > lb <=> exp((la - t2)/tau) > exp((lb - t2)/tau))
      (proved by biconditional natural deduction!)
"""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path
from typing import Any, Dict, FrozenSet, List, Optional, Sequence, Tuple, Union


# =============================================================================
# 1. Immutable Symbolic Syntax Trees (Terms & Propositions)
# =============================================================================

@dataclasses.dataclass(frozen=True)
class Term:
    op: str
    args: Tuple[Any, ...] = ()

    def __str__(self) -> str:
        if self.op == "Var":
            return str(self.args[0])
        if self.op == "Const":
            return str(self.args[0])
        if self.op in ("+", "-", "*", "/"):
            return f"({self.args[0]} {self.op} {self.args[1]})"
        if self.op == "neg":
            return f"(-{self.args[0]})"
        return f"{self.op}({', '.join(str(a) for a in self.args)})"

    def to_json(self) -> Any:
        if self.op in ("Var", "Const"):
            return [self.op, self.args[0]]
        return [self.op] + [a.to_json() if isinstance(a, Term) else a for a in self.args]

    @staticmethod
    def from_json(data: Any) -> "Term":
        op = data[0]
        if op in ("Var", "Const"):
            return Term(op, (data[1],))
        return Term(
            op,
            tuple(
                Term.from_json(x) if isinstance(x, list) else x for x in data[1:]
            ),
        )


def Var(name: str) -> Term:
    return Term("Var", (name,))


def Const(val: int) -> Term:
    return Term("Const", (val,))


def Add(a: Term, b: Term) -> Term:
    return Term("+", (a, b))


def Sub(a: Term, b: Term) -> Term:
    return Term("-", (a, b))


def Mul(a: Term, b: Term) -> Term:
    return Term("*", (a, b))


def Div(a: Term, b: Term) -> Term:
    return Term("/", (a, b))


def Neg(a: Term) -> Term:
    return Term("neg", (a,))


def Exp(a: Term) -> Term:
    return Term("exp", (a,))


def Ln(a: Term) -> Term:
    return Term("ln", (a,))


def Max(a: Term, b: Term) -> Term:
    return Term("max", (a, b))


def Abs(a: Term) -> Term:
    return Term("abs", (a,))


def LSE(a: Term, b: Term, tau: Term) -> Term:
    return Add(
        Max(a, b),
        Mul(tau, Ln(Add(Const(1), Exp(Div(Neg(Abs(Sub(a, b))), tau))))),
    )


def SeqLambda(m: Term) -> Term:
    return Term("LambdaSeq", (m,))


def SeqDecaySum(m: Term, t: Term, tau: Term) -> Term:
    return Term("DecaySum", (m, t, tau))


def IndexedT(idx: Term) -> Term:
    return Term("t_idx", (idx,))


@dataclasses.dataclass(frozen=True)
class Prop:
    kind: str  # "Eq", "Gt", "Ge", "Lt", "Iff", "And", "ForallGe1"
    args: Tuple[Any, ...]

    def __str__(self) -> str:
        if self.kind == "Eq":
            return f"{self.args[0]} = {self.args[1]}"
        if self.kind == "Gt":
            return f"{self.args[0]} > {self.args[1]}"
        if self.kind == "Ge":
            return f"{self.args[0]} >= {self.args[1]}"
        if self.kind == "Lt":
            return f"{self.args[0]} < {self.args[1]}"
        if self.kind == "Iff":
            return f"({self.args[0]} <=> {self.args[1]})"
        if self.kind == "And":
            return f"({self.args[0]} /\\ {self.args[1]})"
        if self.kind == "ForallGe1":
            return f"forall {self.args[0]} >= 1: ({self.args[1]})"
        return f"{self.kind}{self.args}"

    def to_json(self) -> Any:
        def enc(x: Any) -> Any:
            if isinstance(x, (Term, Prop)):
                return x.to_json()
            return x

        return [self.kind] + [enc(a) for a in self.args]

    @staticmethod
    def from_json(data: Any) -> "Prop":
        kind = data[0]
        if kind in ("Eq", "Gt", "Ge", "Lt"):
            return Prop(kind, (Term.from_json(data[1]), Term.from_json(data[2])))
        if kind in ("Iff", "And"):
            return Prop(kind, (Prop.from_json(data[1]), Prop.from_json(data[2])))
        if kind == "ForallGe1":
            return Prop(kind, (data[1], Prop.from_json(data[2])))
        raise ValueError(f"Unknown Prop kind: {kind!r}")


def Eq(a: Term, b: Term) -> Prop:
    return Prop("Eq", (a, b))


def Gt(a: Term, b: Term) -> Prop:
    return Prop("Gt", (a, b))


def Ge(a: Term, b: Term) -> Prop:
    return Prop("Ge", (a, b))


def Lt(a: Term, b: Term) -> Prop:
    return Prop("Lt", (a, b))


def Iff(p: Prop, q: Prop) -> Prop:
    return Prop("Iff", (p, q))


def And(p: Prop, q: Prop) -> Prop:
    return Prop("And", (p, q))


def subst_term(term: Term, var_name: str, replacement: Term) -> Term:
    if term.op == "Var" and term.args[0] == var_name:
        return replacement
    if term.op in ("Var", "Const"):
        return term
    return Term(
        term.op,
        tuple(
            subst_term(a, var_name, replacement) if isinstance(a, Term) else a
            for a in term.args
        ),
    )


def subst_prop(prop: Prop, var_name: str, replacement: Term) -> Prop:
    if prop.kind in ("Eq", "Gt", "Ge", "Lt"):
        return Prop(
            prop.kind,
            (
                subst_term(prop.args[0], var_name, replacement),
                subst_term(prop.args[1], var_name, replacement),
            ),
        )
    if prop.kind in ("Iff", "And"):
        return Prop(
            prop.kind,
            (
                subst_prop(prop.args[0], var_name, replacement),
                subst_prop(prop.args[1], var_name, replacement),
            ),
        )
    if prop.kind == "ForallGe1":
        if prop.args[0] == var_name:
            return prop
        return Prop("ForallGe1", (prop.args[0], subst_prop(prop.args[1], var_name, replacement)))
    raise ValueError(f"Cannot substitute in {prop.kind}")


# =============================================================================
# 2. LCF Trusted Proof Kernel (No `sorry` Rule Exists!)
# =============================================================================

_KERNEL_SECRET = object()


@dataclasses.dataclass(frozen=True)
class Sequent:
    hyps: FrozenSet[Prop]
    concl: Prop

    def to_json(self) -> Dict[str, Any]:
        return {
            "hyps": [h.to_json() for h in sorted(self.hyps, key=str)],
            "concl": self.concl.to_json(),
        }


@dataclasses.dataclass(frozen=True)
class Theorem:
    _token: object
    step_id: int
    sequent: Sequent

    def __post_init__(self) -> None:
        if self._token is not _KERNEL_SECRET:
            raise PermissionError("Theorem objects can only be minted by ProofKernel!")


class ProofKernel:
    """Minimal LCF-style deductive proof kernel recording every inference step."""

    def __init__(self) -> None:
        self.steps: List[Dict[str, Any]] = []

    def _mint(
        self,
        rule: str,
        premises: Sequence[Theorem],
        hyps: FrozenSet[Prop],
        concl: Prop,
        params: Optional[Dict[str, Any]] = None,
    ) -> Theorem:
        step_id = len(self.steps)
        seq = Sequent(hyps=hyps, concl=concl)
        self.steps.append(
            {
                "step_id": step_id,
                "rule": rule,
                "premises": [p.step_id for p in premises],
                "params": params or {},
                "sequent": seq.to_json(),
            }
        )
        return Theorem(_KERNEL_SECRET, step_id, seq)

    # --- Structural & Equality Rules ---
    def assume(self, p: Prop) -> Theorem:
        return self._mint("Assume", [], frozenset([p]), p, {"prop": p.to_json()})

    def refl(self, t: Term) -> Theorem:
        return self._mint("Refl", [], frozenset(), Eq(t, t), {"term": t.to_json()})

    def sym(self, th: Theorem) -> Theorem:
        assert th.sequent.concl.kind == "Eq"
        a, b = th.sequent.concl.args
        return self._mint("Sym", [th], th.sequent.hyps, Eq(b, a))

    def trans(self, th1: Theorem, th2: Theorem) -> Theorem:
        assert th1.sequent.concl.kind == "Eq" and th2.sequent.concl.kind == "Eq"
        a, b1 = th1.sequent.concl.args
        b2, c = th2.sequent.concl.args
        if b1 != b2:
            raise ValueError(f"Trans mismatch:\n  left rhs  = {b1}\n  right lhs = {b2}")
        return self._mint("Trans", [th1, th2], th1.sequent.hyps | th2.sequent.hyps, Eq(a, c))

    def cong_unary(self, op: str, th: Theorem) -> Theorem:
        assert th.sequent.concl.kind == "Eq"
        assert op in ("neg", "exp", "ln", "abs")
        a, b = th.sequent.concl.args
        return self._mint(
            "CongUnary", [th], th.sequent.hyps, Eq(Term(op, (a,)), Term(op, (b,))), {"op": op}
        )

    def cong_binary(self, op: str, th1: Theorem, th2: Theorem) -> Theorem:
        assert th1.sequent.concl.kind == "Eq" and th2.sequent.concl.kind == "Eq"
        assert op in ("+", "-", "*", "/", "max")
        a1, b1 = th1.sequent.concl.args
        a2, b2 = th2.sequent.concl.args
        return self._mint(
            "CongBinary",
            [th1, th2],
            th1.sequent.hyps | th2.sequent.hyps,
            Eq(Term(op, (a1, a2)), Term(op, (b1, b2))),
            {"op": op},
        )

    # --- Positivity Rules (for side-condition discharge) ---
    def pos_exp(self, x: Term) -> Theorem:
        """|- exp(x) > 0"""
        return self._mint("PosExp", [], frozenset(), Gt(Exp(x), Const(0)), {"x": x.to_json()})

    def pos_one_plus_pos(self, th_pos: Theorem) -> Theorem:
        """Gamma |- w > 0  ==>  Gamma |- (1 + w) > 0"""
        assert th_pos.sequent.concl.kind == "Gt" and th_pos.sequent.concl.args[1] == Const(0)
        w = th_pos.sequent.concl.args[0]
        return self._mint(
            "PosOnePlusPos",
            [th_pos],
            th_pos.sequent.hyps,
            Gt(Add(Const(1), w), Const(0)),
        )

    # --- Ordered-Field Algebraic Identities ---
    def add_comm(self, a: Term, b: Term) -> Theorem:
        return self._mint(
            "AddComm", [], frozenset(), Eq(Add(a, b), Add(b, a)),
            {"a": a.to_json(), "b": b.to_json()},
        )

    def add_sub_assoc_div(self, a: Term, b: Term, c: Term, tau: Term, th_tau_pos: Theorem) -> Theorem:
        """Gamma |- tau > 0  ==>  Gamma |- ((a + b) - c) / tau = ((a - c) / tau) + (b / tau)"""
        assert th_tau_pos.sequent.concl == Gt(tau, Const(0))
        lhs = Div(Sub(Add(a, b), c), tau)
        rhs = Add(Div(Sub(a, c), tau), Div(b, tau))
        return self._mint(
            "AddSubAssocDiv",
            [th_tau_pos],
            th_tau_pos.sequent.hyps,
            Eq(lhs, rhs),
            {"a": a.to_json(), "b": b.to_json(), "c": c.to_json(), "tau": tau.to_json()},
        )

    def mul_div_cancel(self, tau: Term, x: Term, th_tau_pos: Theorem) -> Theorem:
        """Gamma |- tau > 0  ==>  Gamma |- (tau * x) / tau = x"""
        assert th_tau_pos.sequent.concl == Gt(tau, Const(0))
        return self._mint(
            "MulDivCancel",
            [th_tau_pos],
            th_tau_pos.sequent.hyps,
            Eq(Div(Mul(tau, x), tau), x),
            {"tau": tau.to_json(), "x": x.to_json()},
        )

    def neg_sub_Antisym(self, a: Term, b: Term) -> Theorem:
        """|- (-(a - b)) = (b - a)"""
        return self._mint(
            "NegSubAntisym",
            [],
            frozenset(),
            Eq(Neg(Sub(a, b)), Sub(b, a)),
            {"a": a.to_json(), "b": b.to_json()},
        )

    def diff_shift_identity(self, x: Term, y: Term, t: Term, tau: Term, th_tau_pos: Theorem) -> Theorem:
        """Gamma |- tau > 0  ==>  Gamma |- (y - x) / tau = ((-(t - y)) / tau) - ((x - t) / tau)"""
        assert th_tau_pos.sequent.concl == Gt(tau, Const(0))
        lhs = Div(Sub(y, x), tau)
        rhs = Sub(Div(Neg(Sub(t, y)), tau), Div(Sub(x, t), tau))
        return self._mint(
            "DiffShiftIdentity",
            [th_tau_pos],
            th_tau_pos.sequent.hyps,
            Eq(lhs, rhs),
            {"x": x.to_json(), "y": y.to_json(), "t": t.to_json(), "tau": tau.to_json()},
        )

    def diff_shift_identity_sym(self, x: Term, y: Term, t: Term, tau: Term, th_tau_pos: Theorem) -> Theorem:
        """Gamma |- tau > 0  ==>  Gamma |- (x - y) / tau = ((x - t) / tau) - ((-(t - y)) / tau)"""
        assert th_tau_pos.sequent.concl == Gt(tau, Const(0))
        lhs = Div(Sub(x, y), tau)
        rhs = Sub(Div(Sub(x, t), tau), Div(Neg(Sub(t, y)), tau))
        return self._mint(
            "DiffShiftIdentitySym",
            [th_tau_pos],
            th_tau_pos.sequent.hyps,
            Eq(lhs, rhs),
            {"x": x.to_json(), "y": y.to_json(), "t": t.to_json(), "tau": tau.to_json()},
        )

    def mul_one_plus_ratio(self, u: Term, v: Term, th_u_pos: Theorem) -> Theorem:
        """Gamma |- u > 0  ==>  Gamma |- u * (1 + (v / u)) = u + v"""
        assert th_u_pos.sequent.concl == Gt(u, Const(0))
        lhs = Mul(u, Add(Const(1), Div(v, u)))
        rhs = Add(u, v)
        return self._mint(
            "MulOnePlusRatio",
            [th_u_pos],
            th_u_pos.sequent.hyps,
            Eq(lhs, rhs),
            {"u": u.to_json(), "v": v.to_json()},
        )

    # --- Transcendental Exp / Ln Rules ---
    def exp_add(self, a: Term, b: Term) -> Theorem:
        """|- exp(a + b) = exp(a) * exp(b)"""
        return self._mint(
            "ExpAdd",
            [],
            frozenset(),
            Eq(Exp(Add(a, b)), Mul(Exp(a), Exp(b))),
            {"a": a.to_json(), "b": b.to_json()},
        )

    def exp_sub(self, a: Term, b: Term) -> Theorem:
        """|- exp(a - b) = exp(a) / exp(b)"""
        return self._mint(
            "ExpSub",
            [],
            frozenset(),
            Eq(Exp(Sub(a, b)), Div(Exp(a), Exp(b))),
            {"a": a.to_json(), "b": b.to_json()},
        )

    def exp_ln_inv(self, th_w_pos: Theorem) -> Theorem:
        """Gamma |- w > 0  ==>  Gamma |- exp(ln(w)) = w"""
        assert th_w_pos.sequent.concl.kind == "Gt" and th_w_pos.sequent.concl.args[1] == Const(0)
        w = th_w_pos.sequent.concl.args[0]
        return self._mint("ExpLnInv", [th_w_pos], th_w_pos.sequent.hyps, Eq(Exp(Ln(w)), w))

    # --- Max / Abs Branch Reductions & Case Split ---
    def max_ge(self, th_ge: Theorem) -> Theorem:
        """Gamma |- a >= b  ==>  Gamma |- max(a, b) = a"""
        assert th_ge.sequent.concl.kind == "Ge"
        a, b = th_ge.sequent.concl.args
        return self._mint("MaxGe", [th_ge], th_ge.sequent.hyps, Eq(Max(a, b), a))

    def abs_sub_ge(self, th_ge: Theorem) -> Theorem:
        """Gamma |- a >= b  ==>  Gamma |- abs(a - b) = a - b"""
        assert th_ge.sequent.concl.kind == "Ge"
        a, b = th_ge.sequent.concl.args
        return self._mint("AbsSubGe", [th_ge], th_ge.sequent.hyps, Eq(Abs(Sub(a, b)), Sub(a, b)))

    def max_lt(self, th_lt: Theorem) -> Theorem:
        """Gamma |- a < b  ==>  Gamma |- max(a, b) = b"""
        assert th_lt.sequent.concl.kind == "Lt"
        a, b = th_lt.sequent.concl.args
        return self._mint("MaxLt", [th_lt], th_lt.sequent.hyps, Eq(Max(a, b), b))

    def abs_sub_lt(self, th_lt: Theorem) -> Theorem:
        """Gamma |- a < b  ==>  Gamma |- abs(a - b) = b - a"""
        assert th_lt.sequent.concl.kind == "Lt"
        a, b = th_lt.sequent.concl.args
        return self._mint("AbsSubLt", [th_lt], th_lt.sequent.hyps, Eq(Abs(Sub(a, b)), Sub(b, a)))

    def case_split_order(self, a: Term, b: Term, th_ge: Theorem, th_lt: Theorem) -> Theorem:
        """Totality of (R, <=):
        Gamma1 u {a >= b} |- P   and   Gamma2 u {a < b} |- P
        ----------------------------------------------------
                       Gamma1 u Gamma2 |- P
        """
        if th_ge.sequent.concl != th_lt.sequent.concl:
            raise ValueError("CaseSplit conclusion mismatch")
        h_ge = Ge(a, b)
        h_lt = Lt(a, b)
        hyps = (th_ge.sequent.hyps - {h_ge}) | (th_lt.sequent.hyps - {h_lt})
        return self._mint(
            "CaseSplitOrder",
            [th_ge, th_lt],
            hyps,
            th_ge.sequent.concl,
            {"a": a.to_json(), "b": b.to_json()},
        )

    # --- Sequence Definitions & Peano Induction on m >= 1 ---
    def def_seq_base_lambda(self) -> Theorem:
        """|- LambdaSeq(1) = t_idx(1)"""
        return self._mint(
            "DefSeqBaseLambda", [], frozenset(), Eq(SeqLambda(Const(1)), IndexedT(Const(1)))
        )

    def def_seq_step_lambda(self, m: Term, tau: Term) -> Theorem:
        """|- LambdaSeq(m + 1) = lse(LambdaSeq(m), t_idx(m + 1), tau)"""
        m1 = Add(m, Const(1))
        return self._mint(
            "DefSeqStepLambda",
            [],
            frozenset(),
            Eq(SeqLambda(m1), LSE(SeqLambda(m), IndexedT(m1), tau)),
            {"m": m.to_json(), "tau": tau.to_json()},
        )

    def def_seq_base_sum(self, t: Term, tau: Term) -> Theorem:
        """|- DecaySum(1, t, tau) = exp((-(t - t_idx(1))) / tau)"""
        return self._mint(
            "DefSeqBaseSum",
            [],
            frozenset(),
            Eq(SeqDecaySum(Const(1), t, tau), Exp(Div(Neg(Sub(t, IndexedT(Const(1)))), tau))),
            {"t": t.to_json(), "tau": tau.to_json()},
        )

    def def_seq_step_sum(self, m: Term, t: Term, tau: Term) -> Theorem:
        """|- DecaySum(m + 1, t, tau) = DecaySum(m, t, tau) + exp((-(t - t_idx(m + 1))) / tau)"""
        m1 = Add(m, Const(1))
        return self._mint(
            "DefSeqStepSum",
            [],
            frozenset(),
            Eq(
                SeqDecaySum(m1, t, tau),
                Add(SeqDecaySum(m, t, tau), Exp(Div(Neg(Sub(t, IndexedT(m1))), tau))),
            ),
            {"m": m.to_json(), "t": t.to_json(), "tau": tau.to_json()},
        )

    def sub_antisym_div_exp(self, a: Term, t: Term) -> Theorem:
        """|- (a - t) = (-(t - a))"""
        return self._mint(
            "SubAntisym", [], frozenset(), Eq(Sub(a, t), Neg(Sub(t, a))),
            {"a": a.to_json(), "t": t.to_json()},
        )

    def nat_induction_ge1(
        self, m_var: str, p_m: Prop, th_base: Theorem, th_step: Theorem
    ) -> Theorem:
        """Mathematical Induction over integers m >= 1:
          Gamma1 |- P[m := 1]
          Gamma2 u {P(m)} |- P[m := m + 1]   (m fresh in Gamma2)
          ------------------------------------------------------
          Gamma1 u Gamma2 |- forall m >= 1: P(m)
        """
        expected_base = subst_prop(p_m, m_var, Const(1))
        expected_step = subst_prop(p_m, m_var, Add(Var(m_var), Const(1)))
        if th_base.sequent.concl != expected_base:
            raise ValueError(f"Induction base mismatch:\n  got {th_base.sequent.concl}\n  exp {expected_base}")
        if th_step.sequent.concl != expected_step:
            raise ValueError(f"Induction step mismatch:\n  got {th_step.sequent.concl}\n  exp {expected_step}")
        step_hyps_clean = th_step.sequent.hyps - {p_m}
        for h in step_hyps_clean:
            if m_var in str(h):
                raise ValueError(f"Induction variable {m_var} occurs free in step hypothesis {h}")
        hyps = th_base.sequent.hyps | step_hyps_clean
        return self._mint(
            "NatInductionGe1",
            [th_base, th_step],
            hyps,
            Prop("ForallGe1", (m_var, p_m)),
            {"m_var": m_var, "p_m": p_m.to_json()},
        )

    # --- Order-Isomorphism Biconditional Rules (for Theorem 1b) ---
    def exp_gt_iff(self, a: Term, b: Term) -> Theorem:
        """|- (exp(a) > exp(b)) <=> (a > b)"""
        return self._mint(
            "ExpGtIff", [], frozenset(), Iff(Gt(Exp(a), Exp(b)), Gt(a, b)),
            {"a": a.to_json(), "b": b.to_json()},
        )

    def div_pos_gt_iff(self, a: Term, b: Term, tau: Term, th_tau_pos: Theorem) -> Theorem:
        """Gamma |- tau > 0  ==>  Gamma |- ((a / tau) > (b / tau)) <=> (a > b)"""
        assert th_tau_pos.sequent.concl == Gt(tau, Const(0))
        return self._mint(
            "DivPosGtIff",
            [th_tau_pos],
            th_tau_pos.sequent.hyps,
            Iff(Gt(Div(a, tau), Div(b, tau)), Gt(a, b)),
            {"a": a.to_json(), "b": b.to_json(), "tau": tau.to_json()},
        )

    def sub_gt_iff(self, a: Term, b: Term, c: Term) -> Theorem:
        """|- ((a - c) > (b - c)) <=> (a > b)"""
        return self._mint(
            "SubGtIff", [], frozenset(), Iff(Gt(Sub(a, c), Sub(b, c)), Gt(a, b)),
            {"a": a.to_json(), "b": b.to_json(), "c": c.to_json()},
        )

    def iff_sym(self, th: Theorem) -> Theorem:
        assert th.sequent.concl.kind == "Iff"
        p, q = th.sequent.concl.args
        return self._mint("IffSym", [th], th.sequent.hyps, Iff(q, p))

    def iff_trans(self, th1: Theorem, th2: Theorem) -> Theorem:
        assert th1.sequent.concl.kind == "Iff" and th2.sequent.concl.kind == "Iff"
        p, q1 = th1.sequent.concl.args
        q2, r = th2.sequent.concl.args
        if q1 != q2:
            raise ValueError(f"IffTrans mismatch: {q1} vs {q2}")
        return self._mint("IffTrans", [th1, th2], th1.sequent.hyps | th2.sequent.hyps, Iff(p, r))

    def and_intro(self, th1: Theorem, th2: Theorem) -> Theorem:
        return self._mint(
            "AndIntro",
            [th1, th2],
            th1.sequent.hyps | th2.sequent.hyps,
            And(th1.sequent.concl, th2.sequent.concl),
        )


# =============================================================================
# 3. Formal Derivations in the LCF Kernel
# =============================================================================

def prove_lse_step(K: ProofKernel, lam: Term, tm1: Term, t: Term, tau: Term, th_tau_pos: Theorem) -> Theorem:
    """Constructive LCF derivation of:
    tau > 0 |- exp((lse(lam, tm1, tau) - t) / tau)
               = exp((lam - t) / tau) + exp((-(t - tm1)) / tau)
    covering BOTH lam >= tm1 and lam < tm1 (non-monotonic clock jitter!).
    """
    u = Exp(Div(Sub(lam, t), tau))
    v = Exp(Div(Neg(Sub(t, tm1)), tau))

    # --- Branch 1: lam >= tm1 ---
    th_ge = K.assume(Ge(lam, tm1))
    th_max_ge = K.max_ge(th_ge)          # max(lam, tm1) = lam
    th_abs_ge = K.abs_sub_ge(th_ge)      # abs(lam - tm1) = lam - tm1
    th_neg_abs = K.cong_unary("neg", th_abs_ge)  # -abs(lam-tm1) = -(lam-tm1)
    th_neg_sub = K.neg_sub_Antisym(lam, tm1)     # -(lam-tm1) = tm1 - lam
    th_num_ge = K.trans(th_neg_abs, th_neg_sub)  # -abs(lam-tm1) = tm1 - lam
    th_div_ge = K.cong_binary("/", th_num_ge, K.refl(tau))  # -abs(..)/tau = (tm1-lam)/tau
    th_exp_ge = K.cong_unary("exp", th_div_ge)
    th_one_plus_ge = K.cong_binary("+", K.refl(Const(1)), th_exp_ge)
    th_ln_ge = K.cong_unary("ln", th_one_plus_ge)
    th_mul_ge = K.cong_binary("*", K.refl(tau), th_ln_ge)
    th_lse_ge = K.cong_binary("+", th_max_ge, th_mul_ge)
    # lse(lam, tm1, tau) = lam + tau * ln(1 + exp((tm1 - lam)/tau))

    inner_ge = Ln(Add(Const(1), Exp(Div(Sub(tm1, lam), tau))))
    th_sub_t_ge = K.cong_binary("-", th_lse_ge, K.refl(t))
    th_div_t_ge = K.cong_binary("/", th_sub_t_ge, K.refl(tau))
    th_split_ge = K.add_sub_assoc_div(lam, Mul(tau, inner_ge), t, tau, th_tau_pos)
    th_cancel_ge = K.mul_div_cancel(tau, inner_ge, th_tau_pos)
    th_rhs_simpl_ge = K.cong_binary("+", K.refl(Div(Sub(lam, t), tau)), th_cancel_ge)
    th_arg_ge = K.trans(th_div_t_ge, K.trans(th_split_ge, th_rhs_simpl_ge))
    th_exp_lhs_ge = K.cong_unary("exp", th_arg_ge)
    th_exp_prod_ge = K.exp_add(Div(Sub(lam, t), tau), inner_ge)
    # exp(ln(1 + exp((tm1-lam)/tau))) = 1 + exp((tm1-lam)/tau)
    th_pos_e1 = K.pos_one_plus_pos(K.pos_exp(Div(Sub(tm1, lam), tau)))
    th_expln_ge = K.exp_ln_inv(th_pos_e1)
    # Rewrite exp((tm1 - lam)/tau) = v / u
    th_shift_ge = K.diff_shift_identity(lam, tm1, t, tau, th_tau_pos)
    th_exp_shift_ge = K.trans(
        K.cong_unary("exp", th_shift_ge),
        K.exp_sub(Div(Neg(Sub(t, tm1)), tau), Div(Sub(lam, t), tau)),
    )
    th_factor_ge = K.trans(th_expln_ge, K.cong_binary("+", K.refl(Const(1)), th_exp_shift_ge))
    th_prod_ge = K.cong_binary("*", K.refl(u), th_factor_ge)
    th_dist_ge = K.mul_one_plus_ratio(u, v, K.pos_exp(Div(Sub(lam, t), tau)))
    branch_ge = K.trans(th_exp_lhs_ge, K.trans(th_exp_prod_ge, K.trans(th_prod_ge, th_dist_ge)))

    # --- Branch 2: lam < tm1 (Clock Jitter / Newer Timestamp) ---
    th_lt = K.assume(Lt(lam, tm1))
    th_max_lt = K.max_lt(th_lt)          # max(lam, tm1) = tm1
    th_abs_lt = K.abs_sub_lt(th_lt)      # abs(lam - tm1) = tm1 - lam
    th_neg_abs_lt = K.cong_unary("neg", th_abs_lt)
    th_neg_sub_lt = K.neg_sub_Antisym(tm1, lam)  # -(tm1 - lam) = lam - tm1
    th_num_lt = K.trans(th_neg_abs_lt, th_neg_sub_lt)
    th_div_lt = K.cong_binary("/", th_num_lt, K.refl(tau))
    th_exp_lt = K.cong_unary("exp", th_div_lt)
    th_one_plus_lt = K.cong_binary("+", K.refl(Const(1)), th_exp_lt)
    th_ln_lt = K.cong_unary("ln", th_one_plus_lt)
    th_mul_lt = K.cong_binary("*", K.refl(tau), th_ln_lt)
    th_lse_lt = K.cong_binary("+", th_max_lt, th_mul_lt)

    inner_lt = Ln(Add(Const(1), Exp(Div(Sub(lam, tm1), tau))))
    th_sub_t_lt = K.cong_binary("-", th_lse_lt, K.refl(t))
    th_div_t_lt = K.cong_binary("/", th_sub_t_lt, K.refl(tau))
    th_split_lt = K.add_sub_assoc_div(tm1, Mul(tau, inner_lt), t, tau, th_tau_pos)
    th_cancel_lt = K.mul_div_cancel(tau, inner_lt, th_tau_pos)
    # Rewrite (tm1 - t)/tau = (-(t - tm1))/tau
    th_tm1_antisym = K.cong_binary("/", K.sub_antisym_div_exp(tm1, t), K.refl(tau))
    th_rhs_simpl_lt = K.cong_binary("+", th_tm1_antisym, th_cancel_lt)
    th_arg_lt = K.trans(th_div_t_lt, K.trans(th_split_lt, th_rhs_simpl_lt))
    th_exp_lhs_lt = K.cong_unary("exp", th_arg_lt)
    th_exp_prod_lt = K.exp_add(Div(Neg(Sub(t, tm1)), tau), inner_lt)
    th_pos_e2 = K.pos_one_plus_pos(K.pos_exp(Div(Sub(lam, tm1), tau)))
    th_expln_lt = K.exp_ln_inv(th_pos_e2)
    th_shift_lt = K.diff_shift_identity_sym(lam, tm1, t, tau, th_tau_pos)
    th_exp_shift_lt = K.trans(
        K.cong_unary("exp", th_shift_lt),
        K.exp_sub(Div(Sub(lam, t), tau), Div(Neg(Sub(t, tm1)), tau)),
    )
    th_factor_lt = K.trans(th_expln_lt, K.cong_binary("+", K.refl(Const(1)), th_exp_shift_lt))
    th_prod_lt = K.cong_binary("*", K.refl(v), th_factor_lt)
    th_dist_lt = K.mul_one_plus_ratio(v, u, K.pos_exp(Div(Neg(Sub(t, tm1)), tau)))
    th_comm_lt = K.add_comm(v, u)
    branch_lt = K.trans(
        th_exp_lhs_lt,
        K.trans(th_exp_prod_lt, K.trans(th_prod_lt, K.trans(th_dist_lt, th_comm_lt))),
    )

    return K.case_split_order(lam, tm1, branch_ge, branch_lt)


def build_all_deductive_proofs() -> Tuple[ProofKernel, Dict[str, Theorem]]:
    K = ProofKernel()
    tau = Var("tau")
    t = Var("t")
    m = Var("m")
    th_tau_pos = K.assume(Gt(tau, Const(0)))

    # 1. Single-Step Exact Equivalence (Theorem 1a-Step)
    th_step_gen = prove_lse_step(K, Var("lam"), Var("tm1"), t, tau, th_tau_pos)

    # 2. Full Inductive Equivalence over m >= 1 Visits (Theorem 1a-Induction)
    # P(m): exp((LambdaSeq(m) - t) / tau) = DecaySum(m, t, tau)
    p_m = Eq(Exp(Div(Sub(SeqLambda(m), t), tau)), SeqDecaySum(m, t, tau))

    # Base case m = 1:
    t1 = IndexedT(Const(1))
    th_b1 = K.def_seq_base_lambda()  # LambdaSeq(1) = t_idx(1)
    th_b2 = K.cong_binary("-", th_b1, K.refl(t))
    th_b3 = K.trans(th_b2, K.sub_antisym_div_exp(t1, t))
    th_b4 = K.cong_unary("exp", K.cong_binary("/", th_b3, K.refl(tau)))
    th_b5 = K.sym(K.def_seq_base_sum(t, tau))
    th_base = K.trans(th_b4, th_b5)

    # Inductive step m -> m + 1:
    m1 = Add(m, Const(1))
    tm1_idx = IndexedT(m1)
    th_ih = K.assume(p_m)
    th_def_lam_m1 = K.def_seq_step_lambda(m, tau)
    th_lhs_m1 = K.cong_unary(
        "exp", K.cong_binary("/", K.cong_binary("-", th_def_lam_m1, K.refl(t)), K.refl(tau))
    )
    th_lse_m = prove_lse_step(K, SeqLambda(m), tm1_idx, t, tau, th_tau_pos)
    th_use_ih = K.cong_binary("+", th_ih, K.refl(Exp(Div(Neg(Sub(t, tm1_idx)), tau))))
    th_fold_sum = K.sym(K.def_seq_step_sum(m, t, tau))
    th_ind_step = K.trans(th_lhs_m1, K.trans(th_lse_m, K.trans(th_use_ih, th_fold_sum)))

    th_induction = K.nat_induction_ge1("m", p_m, th_base, th_ind_step)

    # 3. Time-Translation Order Invariance (Theorem 1b)
    la, lb = Var("la"), Var("lb")
    t1_v, t2_v = Var("t1"), Var("t2")

    def prove_score_iff_lam(tref: Term) -> Theorem:
        c1 = K.exp_gt_iff(Div(Sub(la, tref), tau), Div(Sub(lb, tref), tau))
        c2 = K.div_pos_gt_iff(Sub(la, tref), Sub(lb, tref), tau, th_tau_pos)
        c3 = K.sub_gt_iff(la, lb, tref)
        return K.iff_trans(c1, K.iff_trans(c2, c3))

    th_t1_iff_lam = prove_score_iff_lam(t1_v)
    th_t2_iff_lam = prove_score_iff_lam(t2_v)
    th_lam_iff_t2 = K.iff_sym(th_t2_iff_lam)
    th_order_invariance = K.and_intro(th_t1_iff_lam, th_lam_iff_t2)

    return K, {
        "Theorem_1a_SingleStep_JitterSafe": th_step_gen,
        "Theorem_1a_Inductive_Equivalence": th_induction,
        "Theorem_1b_TimeTranslation_OrderInvariance": th_order_invariance,
    }


# =============================================================================
# 4. Independent Certificate Verifier (Zero Shared State with ProofKernel!)
# =============================================================================

def verify_certificate_dict(cert: Dict[str, Any]) -> Tuple[bool, int]:
    """Independently audit every step in a serialized proof certificate."""
    steps = cert["steps"]
    verified: Dict[int, Tuple[FrozenSet[Prop], Prop]] = {}

    for entry in steps:
        sid = entry["step_id"]
        rule = entry["rule"]
        prem_ids = entry["premises"]
        params = entry["params"]
        claimed_hyps = frozenset(Prop.from_json(h) for h in entry["sequent"]["hyps"])
        claimed_concl = Prop.from_json(entry["sequent"]["concl"])

        if rule == "Sorry":
            raise AssertionError("Certificate rejected: forbidden 'Sorry' rule encountered!")

        prems = [verified[pid] for pid in prem_ids]

        if rule == "Assume":
            p = Prop.from_json(params["prop"])
            exp_hyps, exp_concl = frozenset([p]), p
        elif rule == "Refl":
            t = Term.from_json(params["term"])
            exp_hyps, exp_concl = frozenset(), Eq(t, t)
        elif rule == "Sym":
            (h1, c1), = prems
            assert c1.kind == "Eq"
            exp_hyps, exp_concl = h1, Eq(c1.args[1], c1.args[0])
        elif rule == "Trans":
            (h1, c1), (h2, c2) = prems
            assert c1.kind == "Eq" and c2.kind == "Eq" and c1.args[1] == c2.args[0]
            exp_hyps, exp_concl = h1 | h2, Eq(c1.args[0], c2.args[1])
        elif rule == "CongUnary":
            (h1, c1), = prems
            op = params["op"]
            assert c1.kind == "Eq" and op in ("neg", "exp", "ln", "abs")
            exp_hyps, exp_concl = h1, Eq(Term(op, (c1.args[0],)), Term(op, (c1.args[1],)))
        elif rule == "CongBinary":
            (h1, c1), (h2, c2) = prems
            op = params["op"]
            assert c1.kind == "Eq" and c2.kind == "Eq" and op in ("+", "-", "*", "/", "max")
            exp_hyps = h1 | h2
            exp_concl = Eq(Term(op, (c1.args[0], c2.args[0])), Term(op, (c1.args[1], c2.args[1])))
        elif rule == "PosExp":
            x = Term.from_json(params["x"])
            exp_hyps, exp_concl = frozenset(), Gt(Exp(x), Const(0))
        elif rule == "PosOnePlusPos":
            (h1, c1), = prems
            assert c1.kind == "Gt" and c1.args[1] == Const(0)
            exp_hyps, exp_concl = h1, Gt(Add(Const(1), c1.args[0]), Const(0))
        elif rule == "AddComm":
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            exp_hyps, exp_concl = frozenset(), Eq(Add(a, b), Add(b, a))
        elif rule == "AddSubAssocDiv":
            (h1, c1), = prems
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            c, tau = Term.from_json(params["c"]), Term.from_json(params["tau"])
            assert c1 == Gt(tau, Const(0))
            exp_hyps = h1
            exp_concl = Eq(Div(Sub(Add(a, b), c), tau), Add(Div(Sub(a, c), tau), Div(b, tau)))
        elif rule == "MulDivCancel":
            (h1, c1), = prems
            tau, x = Term.from_json(params["tau"]), Term.from_json(params["x"])
            assert c1 == Gt(tau, Const(0))
            exp_hyps, exp_concl = h1, Eq(Div(Mul(tau, x), tau), x)
        elif rule == "NegSubAntisym":
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            exp_hyps, exp_concl = frozenset(), Eq(Neg(Sub(a, b)), Sub(b, a))
        elif rule == "DiffShiftIdentity":
            (h1, c1), = prems
            x, y = Term.from_json(params["x"]), Term.from_json(params["y"])
            t, tau = Term.from_json(params["t"]), Term.from_json(params["tau"])
            assert c1 == Gt(tau, Const(0))
            exp_hyps = h1
            exp_concl = Eq(Div(Sub(y, x), tau), Sub(Div(Neg(Sub(t, y)), tau), Div(Sub(x, t), tau)))
        elif rule == "DiffShiftIdentitySym":
            (h1, c1), = prems
            x, y = Term.from_json(params["x"]), Term.from_json(params["y"])
            t, tau = Term.from_json(params["t"]), Term.from_json(params["tau"])
            assert c1 == Gt(tau, Const(0))
            exp_hyps = h1
            exp_concl = Eq(Div(Sub(x, y), tau), Sub(Div(Sub(x, t), tau), Div(Neg(Sub(t, y)), tau)))
        elif rule == "MulOnePlusRatio":
            (h1, c1), = prems
            u, v = Term.from_json(params["u"]), Term.from_json(params["v"])
            assert c1 == Gt(u, Const(0))
            exp_hyps, exp_concl = h1, Eq(Mul(u, Add(Const(1), Div(v, u))), Add(u, v))
        elif rule == "ExpAdd":
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            exp_hyps, exp_concl = frozenset(), Eq(Exp(Add(a, b)), Mul(Exp(a), Exp(b)))
        elif rule == "ExpSub":
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            exp_hyps, exp_concl = frozenset(), Eq(Exp(Sub(a, b)), Div(Exp(a), Exp(b)))
        elif rule == "ExpLnInv":
            (h1, c1), = prems
            assert c1.kind == "Gt" and c1.args[1] == Const(0)
            exp_hyps, exp_concl = h1, Eq(Exp(Ln(c1.args[0])), c1.args[0])
        elif rule == "MaxGe":
            (h1, c1), = prems
            assert c1.kind == "Ge"
            exp_hyps, exp_concl = h1, Eq(Max(c1.args[0], c1.args[1]), c1.args[0])
        elif rule == "AbsSubGe":
            (h1, c1), = prems
            assert c1.kind == "Ge"
            exp_hyps, exp_concl = h1, Eq(Abs(Sub(c1.args[0], c1.args[1])), Sub(c1.args[0], c1.args[1]))
        elif rule == "MaxLt":
            (h1, c1), = prems
            assert c1.kind == "Lt"
            exp_hyps, exp_concl = h1, Eq(Max(c1.args[0], c1.args[1]), c1.args[1])
        elif rule == "AbsSubLt":
            (h1, c1), = prems
            assert c1.kind == "Lt"
            exp_hyps, exp_concl = h1, Eq(Abs(Sub(c1.args[0], c1.args[1])), Sub(c1.args[1], c1.args[0]))
        elif rule == "CaseSplitOrder":
            (h1, c1), (h2, c2) = prems
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            assert c1 == c2
            exp_hyps = (h1 - {Ge(a, b)}) | (h2 - {Lt(a, b)})
            exp_concl = c1
        elif rule == "DefSeqBaseLambda":
            exp_hyps, exp_concl = frozenset(), Eq(SeqLambda(Const(1)), IndexedT(Const(1)))
        elif rule == "DefSeqStepLambda":
            m, tau = Term.from_json(params["m"]), Term.from_json(params["tau"])
            m1 = Add(m, Const(1))
            exp_hyps, exp_concl = frozenset(), Eq(SeqLambda(m1), LSE(SeqLambda(m), IndexedT(m1), tau))
        elif rule == "DefSeqBaseSum":
            t, tau = Term.from_json(params["t"]), Term.from_json(params["tau"])
            exp_hyps = frozenset()
            exp_concl = Eq(SeqDecaySum(Const(1), t, tau), Exp(Div(Neg(Sub(t, IndexedT(Const(1)))), tau)))
        elif rule == "DefSeqStepSum":
            m = Term.from_json(params["m"])
            t, tau = Term.from_json(params["t"]), Term.from_json(params["tau"])
            m1 = Add(m, Const(1))
            exp_hyps = frozenset()
            exp_concl = Eq(
                SeqDecaySum(m1, t, tau),
                Add(SeqDecaySum(m, t, tau), Exp(Div(Neg(Sub(t, IndexedT(m1))), tau))),
            )
        elif rule == "SubAntisym":
            a, t = Term.from_json(params["a"]), Term.from_json(params["t"])
            exp_hyps, exp_concl = frozenset(), Eq(Sub(a, t), Neg(Sub(t, a)))
        elif rule == "NatInductionGe1":
            (h_base, c_base), (h_step, c_step) = prems
            m_var = params["m_var"]
            p_m = Prop.from_json(params["p_m"])
            assert c_base == subst_prop(p_m, m_var, Const(1))
            assert c_step == subst_prop(p_m, m_var, Add(Var(m_var), Const(1)))
            clean_step = h_step - {p_m}
            for h in clean_step:
                assert m_var not in str(h)
            exp_hyps = h_base | clean_step
            exp_concl = Prop("ForallGe1", (m_var, p_m))
        elif rule == "ExpGtIff":
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            exp_hyps, exp_concl = frozenset(), Iff(Gt(Exp(a), Exp(b)), Gt(a, b))
        elif rule == "DivPosGtIff":
            (h1, c1), = prems
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            tau = Term.from_json(params["tau"])
            assert c1 == Gt(tau, Const(0))
            exp_hyps, exp_concl = h1, Iff(Gt(Div(a, tau), Div(b, tau)), Gt(a, b))
        elif rule == "SubGtIff":
            a, b = Term.from_json(params["a"]), Term.from_json(params["b"])
            c = Term.from_json(params["c"])
            exp_hyps, exp_concl = frozenset(), Iff(Gt(Sub(a, c), Sub(b, c)), Gt(a, b))
        elif rule == "IffSym":
            (h1, c1), = prems
            assert c1.kind == "Iff"
            exp_hyps, exp_concl = h1, Iff(c1.args[1], c1.args[0])
        elif rule == "IffTrans":
            (h1, c1), (h2, c2) = prems
            assert c1.kind == "Iff" and c2.kind == "Iff" and c1.args[1] == c2.args[0]
            exp_hyps, exp_concl = h1 | h2, Iff(c1.args[0], c2.args[1])
        elif rule == "AndIntro":
            (h1, c1), (h2, c2) = prems
            exp_hyps, exp_concl = h1 | h2, And(c1, c2)
        else:
            raise AssertionError(f"Unknown inference rule in certificate: {rule!r}")

        if exp_hyps != claimed_hyps or exp_concl != claimed_concl:
            raise AssertionError(
                f"Step {sid} ({rule}) sequent mismatch!\n"
                f"  expected: {set(map(str, exp_hyps))} |- {exp_concl}\n"
                f"  claimed : {set(map(str, claimed_hyps))} |- {claimed_concl}"
            )
        verified[sid] = (exp_hyps, exp_concl)

    for name, tid in cert["theorems"].items():
        assert tid in verified, f"Missing theorem step {tid} for {name}"

    return True, len(steps)


def run_and_export(cert_path: Optional[Path] = None) -> Dict[str, Any]:
    K, thms = build_all_deductive_proofs()
    cert = {
        "kernel": "znav-lcf-deductive-v1",
        "sorry_count": 0,
        "steps": K.steps,
        "theorems": {k: v.step_id for k, v in thms.items()},
    }
    if cert_path is not None:
        cert_path.write_text(json.dumps(cert, indent=2) + "\n", encoding="utf-8")
        reloaded = json.loads(cert_path.read_text(encoding="utf-8"))
        ok, n_steps = verify_certificate_dict(reloaded)
    else:
        ok, n_steps = verify_certificate_dict(cert)
    assert ok
    return {"ok": ok, "num_steps": n_steps, "theorems": {k: str(v.sequent.concl) for k, v in thms.items()}}


if __name__ == "__main__":
    out_file = Path(__file__).resolve().parent / "deductive_certificates.json"
    summary = run_and_export(out_file)
    print(f"[LCF Deductive Kernel] Verified {summary['num_steps']} primitive inference steps (0 sorrys).")
    for tname, stmt in summary["theorems"].items():
        print(f"  [PROVED] {tname}:\n    tau > 0 |- {stmt}")
    print("DEDUCTIVE KERNEL VERIFICATION: QED")
