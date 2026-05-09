# Three primary outcomes for the ranking experiment

## Setup

Two arms. Control respondents rank a fixed set of $K$ options ($K \in \{4, 5, 6\}$). Treated respondents rank the same options after receiving a treatment. Rankings are full and strict — every respondent submits a complete ordering. The headline claim is that the treatment changes the *population's preference structure*. There is no welfare benchmark (no objectively "correct" ranking), and the relevant aggregation rule is generic — any reasonable voting rule should be considered, not one specific institution.

The three outcomes below correspond to three distinct questions: where pairwise preferences moved, whether respondents' rankings became more or less mutually coherent, and what these distributional changes mean when rankings are aggregated into group decisions.

## Idea

**Outcome 1 — Pairwise preference matrix.** For every pair of options, ask: did treatment make people more likely to prefer A over B? You get one number per pair. This tells you *where preferences moved and in what direction.*

**Outcome 2 — Kendall dispersion.** Pick two random people from the same arm and count how often they disagree on pairs of options. Did treatment make people agree with each other more, or less? This tells you *whether rankings became more similar across people, or more spread out.*

**Outcome 3 — Voting-rule panel.** Pretend to assemble small groups (say, 5 people) from each arm and run a vote. Did treatment change who wins? Test this under several common voting rules. This tells you *whether the preference changes actually matter for group decisions.*

The logic chain: Outcome 1 says preferences shifted. Outcome 2 says people moved together or apart. Outcome 3 says these shifts do (or don't) change what a group would pick.

---

## Outcome 1 (primary): Pairwise preference ATE matrix

### The estimand

For every pair of options $(j, k)$, define an indicator $Y_{ijk} = 1$ if respondent $i$ ranks option $j$ above option $k$. The arm-specific pairwise preference probabilities are

$$p^T_{jk} = P_T(j \succ k), \qquad p^C_{jk} = P_C(j \succ k),$$

and the pairwise treatment effect is

$$\tau_{jk} = p^T_{jk} - p^C_{jk}.$$

With $K$ options there are $\binom{K}{2}$ such pairs (between 6 and 15 depending on $K$). The full set $\{\tau_{jk}\}$ is the pairwise preference ATE matrix; the level matrices $\{p^T_{jk}\}$ and $\{p^C_{jk}\}$ are reported alongside it.

### Why this leads

The pairwise preference matrix is the natural model-free summary of average preference structure at the level of ordered pairs. It captures, for each pair of options, whether the treatment makes respondents more likely to prefer one to the other. It is informationally rich at this level: rank-position ATEs and Borda-score ATEs are linear functionals of the pairwise ATE matrix, and any aggregation rule that depends on the data only through pairwise majorities (Condorcet, Copeland, Schulze, Kemeny) takes the pairwise matrix as its primitive at the level of realized group profiles.

The matrix is also robust to the modal failure case under a persuasion-flavored intervention. A treatment that flips a pairwise majority — moving $p_{jk}$ from, say, 0.4 to 0.6 — is a large preference-structure change. It shows up cleanly in $\tau_{jk}$ regardless of whether interpersonal dispersion changes. Scalar consensus measures can miss this entirely (see Outcome 2).

A caveat that matters for honest framing: the pairwise marginal matrix is *not* the full distribution over rankings. For $K \ge 4$, many distinct ranking distributions can produce the same pairwise marginals. The matrix is the right primary projection of preference structure, not the entire object. Outcome 3, which uses full rankings directly, is where the joint distribution becomes load-bearing.

### Inference

Each $\tau_{jk}$ is a difference in means; standard errors must account for within-respondent clustering because each respondent contributes to all $\binom{K}{2}$ indicators. Apply Romano–Wolf multiplicity correction across pairs to control family-wise error while accounting for dependence among the pairwise tests. Benjamini–Hochberg is a defensible alternative for FDR control on the discovery set; pre-register one.

Report three scalars alongside the matrix:

1. **Joint omnibus Wald statistic** for $H_0 : \tau_{jk} = 0 \ \forall (j,k)$ — the significance scalar.
2. **RMS pairwise shift**, $\sqrt{\binom{K}{2}^{-1} \sum_{j<k} \hat\tau_{jk}^2}$ — the magnitude scalar in percentage points.
3. **The full matrix display**, with significance markers from the multiplicity-corrected pairwise tests.

Do not report a *signed* aggregate of the pairwise effects (e.g., mean signed shift across pairs). Such an aggregate depends on the labeling convention for which option in a pair is called "$j$" and is generally meaningless without a substantive ordering of options. RMS handles this correctly because it squares.

### What it answers

Where in the ranking distribution the treatment moved respondents at the level of pairwise comparisons. Which pairwise comparisons shifted, in what direction, and by how much.

---

## Outcome 2 (companion): Kendall dispersion

### The estimand

Kendall tau distance between two rankings is the share of option pairs they disagree on. The estimand is the difference in average within-arm Kendall distance between two randomly drawn respondents:

$$\Delta = E\big[d_\tau(R_i, R_{i'}) \mid D_i = D_{i'} = 1\big] - E\big[d_\tau(R_i, R_{i'}) \mid D_i = D_{i'} = 0\big].$$

A negative $\Delta$ means treated respondents agree with each other more than control respondents do — rankings became more mutually coherent. A positive $\Delta$ means rankings became more dispersed.

### Why it sits next to Outcome 1

The matrix in Outcome 1 captures the marginal pairwise probabilities. Kendall dispersion captures interpersonal coherence — a higher-order functional of the same ranking distribution. Treatments can shift the pairwise marginals without changing within-arm coherence, change coherence without moving the marginal majorities much, or both. Reporting the matrix and the dispersion together identifies which is happening; either alone leaves the reader guessing.

The expected within-arm Kendall distance has a clean expression in terms of the level matrices:

$$E[d_\tau \mid d] = \binom{K}{2}^{-1} \sum_{j<k} 2 p^d_{jk}(1 - p^d_{jk}).$$

Two implications worth stating cleanly. First, $\Delta$ depends on the *level* matrices $\{p^T_{jk}\}$ and $\{p^C_{jk}\}$, not on the ATE matrix $\{\tau_{jk}\}$ alone — the dispersion ATE is not recoverable from the pairwise ATE matrix without the levels. Second, the per-pair contribution $2p_{jk}(1-p_{jk})$ is symmetric around $p_{jk} = 0.5$. A treatment that flips a pairwise majority from 0.4 to 0.6 produces *zero* effect on this measure; the directional preference change is invisible to it. This is exactly why Kendall dispersion cannot stand alone as the primary under a preference-structure framing — it is a coherence complement to the pairwise matrix, not a substitute for it.

### Why "dispersion," not "polarization"

Higher Kendall dispersion means more interpersonal disagreement on pairwise orderings. It is consistent with several distinct data-generating processes: genuine polarization (clustering around opposing ranking types), random noise added to a common ranking, or heterogeneous responses to the treatment along observable dimensions. Polarization is a structural claim about bimodality or factional clustering; Kendall dispersion is a scalar of total disagreement. Use the word "dispersion" in the body of the paper. If the question of polarization specifically is substantively relevant, conduct an explicit appendix check for clustering in the ranking distribution along observable covariates — that is a different test, not a relabeling of Outcome 2.

### Inference

The estimator is a U-statistic over within-arm pairs of respondents. The effective sample size is the number of respondents, not the number of respondent-pairs. Variance scales as $\sigma^2/N$ via the Hájek projection, despite the $\binom{N}{2}$ pairs in the sum, because individuals reappear across pairs. Use the standard U-statistic variance formula, an individual-level bootstrap, or randomization inference. Do not treat respondent-pairs as independent observations.

### What it answers

Whether treated respondents' rankings became more or less mutually coherent — whether the within-arm joint ranking distribution tightened or spread.

---

## Outcome 3 (collective-choice consequence): Rule-output panel under randomization inference

### The estimand

The first two outcomes characterize the within-arm ranking distribution. This one pushes those distributional changes through to the question of what happens when rankings are aggregated into group decisions. Construct synthetic groups by drawing $k$ respondents at random from within each arm. For each synthetic group, compute outcomes under several voting rules:

1. Probability that a Condorcet winner exists (an option that beats every other option in pairwise majority comparison within the group).
2. Distribution over which option wins, under plurality, Borda, IRV, and Copeland.
3. Optional: Smith-set size, expected winning margin.

Report the treatment-control difference on each. Group size $k = 5$ is the primary specification; $k = 7$ is the larger-group robustness; sweep $k \in \{3, 5, 7, 9\}$ in the appendix.

Avoid even $k$ as the headline. At even $k$, pairwise majorities can split exactly $k/2$ to $k/2$, and the Condorcet indicator then requires a tie-breaking convention (strict majority, weak majority, random selection). Different conventions give different answers, and pre-registration cannot fully neutralize the arbitrariness. Odd $k$ avoids the issue.

### Why this is the third outcome

Outcomes 1 and 2 are about the within-arm ranking distribution. This one tests whether changes in that distribution translate into changes in collective decisions under generic aggregation. Because the design does not privilege a single voting rule, examining several common rules tells you whether the observed preference-structure changes have broad collective-choice consequences or are specific to particular rules. Either pattern is informative.

A connection worth stating: the pairwise voting rules (Condorcet, Copeland, etc.) are functions of the pairwise margin matrix *for a realized group profile*. The *distribution* of winners across synthetic groups, however, depends on the joint distribution of full rankings — not only the marginal pairwise probabilities the Outcome 1 matrix captures. This is why Outcome 3 takes full rankings as input rather than reconstructing winners from the pairwise ATE matrix, and it is the substantive reason the trio needs all three components.

### Inference: randomization, not bootstrap

Two motivations, both real. First, voting rules are argmax operators; near tipping configurations, small changes in the sample flip the winner discontinuously. Standard bootstrap inference can be unreliable near these tipping configurations because the rule-output functional is non-smooth. Second, synthetic groups are not independent observations — they are a simulation device for estimating a functional of the within-arm ranking distribution. Generating a million synthetic groups does not create a million independent data points; the experimental units remain the $N$ respondents.

The procedure: permute treatment labels across respondents according to the experimental assignment mechanism. For each permutation, redraw synthetic groups within the permuted arms and recompute the rule-output statistics. The reference distribution for the test statistic is built from the permutations. This yields exact finite-sample tests under the sharp null of no individual treatment effect on rankings, and it correctly avoids treating synthetic groups as independent observations.

Operationally: each permutation should draw enough synthetic groups (a few thousand at $k \le 7$) that Monte Carlo error from the resampling is dominated by the permutation distribution itself. Synthetic groups are drawn *within arm* only — cross-arm groups have no clean interpretation under the design.

### What it answers

Whether the preference-structure changes documented in Outcomes 1 and 2 translate into different collective decisions, and whether that translation is robust across aggregation rules.

---

## How the three fit together

The trio characterizes treatment effects on three distinct functionals of the within-arm ranking distribution. Outcome 1 summarizes the marginal pairwise structure: which pairwise preferences moved. Outcome 2 summarizes the within-arm coherence of the joint ranking distribution: did respondents' rankings become more or less similar to one another. Outcome 3 summarizes the consequences of the joint distribution for collective-choice outputs under generic aggregation: do these changes matter for what voting rules select.

The pairwise ATE matrix leads because the abstract claim is about preference structure, and the matrix is the natural model-free summary at the level of pairwise comparisons. The omnibus Wald statistic and the RMS pairwise shift give the one-number significance and magnitude scalars. Kendall dispersion sits next to it as the coherence companion, with the symmetry-around-$0.5$ caveat stated openly. The rule-output panel under randomization inference sits as the collective-choice consequence.

If the paper's framing later shifts toward consensus, coherence, or coordination as the headline construct rather than preference structure, the ordering should flip: Kendall dispersion becomes primary, and the pairwise matrix becomes the directional decomposition. The trio is the same; the lead changes with the abstract sentence.

### Summary table

| # | Outcome | What it measures | Inference |
|---|---|---|---|
| 1 | Pairwise preference ATE matrix $\{\tau_{jk}\}$ | Directional shifts in average pairwise preferences | Diff-in-means per pair, individual-clustered SEs, Romano–Wolf across pairs, joint Wald omnibus, RMS magnitude scalar |
| 2 | Kendall dispersion ATE $\Delta$ | Within-arm interpersonal disagreement / ranking coherence | U-statistic, Hájek-projection variance or individual-level bootstrap |
| 3 | Rule-output panel ($k=5$ primary; $k \in \{3,5,7,9\}$ in appendix) | Consequences for synthetic-group decisions under plurality, Borda, IRV, Copeland, Condorcet | Randomization inference at the individual assignment level |

### Pre-registration checklist

- Multiplicity correction for Outcome 1: Romano–Wolf (default) or BH (alternative); commit to one.
- Headline scalars for Outcome 1: joint Wald and RMS pairwise shift; do not report mean signed shift.
- Variance procedure for Outcome 2: Hájek-projection U-statistic variance; bootstrap as robustness.
- "Polarization" reserved for explicit covariate-based clustering check in appendix; body uses "dispersion."
- Synthetic group sizes for Outcome 3: $k = 5$ primary, $k = 7$ secondary, sweep $\{3,5,7,9\}$ appendix; no even $k$.
- Synthetic groups drawn within arm only.
- Inference for Outcome 3: randomization inference at the individual assignment level, with Monte Carlo resampling counts pre-specified.
