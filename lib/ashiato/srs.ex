defmodule Ashiato.Srs do
  @moduledoc """
  The FSRS-6 scheduler as pure functions over `Ashiato.Schemas.WordState`: no Repo,
  no clock, no IO (§6.4 — FSRS computes from grades alone).

  Sources (FSRS-6, 21 weights):

    * Formulas — fsrs-rs `model_v6.rs`, matching the awesome-fsrs wiki:
      https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm
    * Default parameters `w0..w20` — the wiki's "FSRS-6" section.

  The model contract: stability in 0.0001..36500.0 days, difficulty in
  1.0..10.0, and states `:new`, `:learning`, `:review`, `:relearning`. Sub-day
  remedial steps are scheduler state outside this module (R3.13); same-day
  reviews still use FSRS-6's short-term stability formula, because a remedial
  step or a re-encounter can arrive before the day is over.

  The curves:

      R(t, S) = (1 + FACTOR * t / S) ** DECAY          # retrievability
      I(r, S) = S / FACTOR * (r ** (1/DECAY) - 1)      # interval for retention r

  with the trainable DECAY = -w20 and FACTOR = 0.9 ** (1/DECAY) - 1, so
  `I(0.9, S)` is exactly `S`: at the default desired retention of 0.9, a day
  count is a day count.
  """

  alias Ashiato.Schemas.WordState

  @typedoc "The FSRS grade: 1 = again, 2 = hard, 3 = good, 4 = easy."
  @type grade :: 1..4

  @grade_again 1
  @grade_hard 2
  @grade_good 3
  @grade_easy 4

  # FSRS-6 default weights w0..w20 (awesome-fsrs wiki, "FSRS-6" section):
  # w0..w3 initial stability per grade, w4..w5 initial difficulty,
  # w6..w7 difficulty updates and mean reversion, w8..w10 post-success growth,
  # w11..w14 post-lapse stability, w15 hard penalty, w16 easy bonus,
  # w17..w19 short-term stability, w20 trainable forgetting-curve decay.
  @weights [
    # 0
    0.212,
    1.2931,
    2.3065,
    8.2956,
    6.4133,
    # 5
    0.8334,
    3.0194,
    0.001,
    1.8722,
    0.1666,
    # 10
    0.796,
    1.4835,
    0.0614,
    0.2629,
    1.6483,
    # 15
    0.6014,
    1.8729,
    0.5425,
    0.0912,
    0.0658,
    0.1542
  ]

  @desired_retention 0.9
  @decay -Enum.at(@weights, 20)
  @factor :math.pow(0.9, 1 / @decay) - 1

  @s_min 0.0001
  @s_max 36_500.0
  @d_min 1.0
  @d_max 10.0

  @maturity_days 21
  @massed_min_occurrences 5
  @massed_min_density 4.0
  @massed_min_days 1

  @doc """
  Grades one review and returns the next FSRS state.

  `word_state` is the current `%Ashiato.Schemas.WordState{}` (state `:new`,
  `:learning`, `:review` or `:relearning`; `last_reviewed_at` may be nil for a
  never-reviewed word, and the latter three imply `stability`/`difficulty` are
  set). `grade` is the FSRS grade 1..4: 1 again, 2 hard, 3 good, 4 easy. `now`
  is any `DateTime`, fractional or not.

  Returns `%{state: %Ashiato.Schemas.WordState{}, interval_days: integer()}` — the
  updated struct (same `word_id`, new state/stability/difficulty/reps/lapses,
  `last_reviewed_at = now`, `due_at = now + interval_days`) plus the integer
  FSRS interval that `due_at` was computed from.

  Elapsed days `t` is `max(0, round(days between last_reviewed_at and now))`,
  as in FSRS-6 — only meaningful once the word has stability and difficulty
  (`:learning`, `:review` or `:relearning`), from which the retrievability
  `R(t, S)` is computed. `t == 0` selects the short-term stability formula.
  """
  @spec grade(WordState.t(), grade(), DateTime.t()) :: %{
          state: WordState.t(),
          interval_days: integer()
        }
  def grade(%WordState{} = word_state, grade, %DateTime{} = now)
      when grade in [@grade_again, @grade_hard, @grade_good, @grade_easy] do
    if word_state.state == :new do
      initial_review(word_state, grade, now)
    else
      reviewed(word_state, grade, now)
    end
  end

  @doc """
  Whether a word has crossed `threshold` days of stability (default 21).

  Maturity is stability-based, never interval-based: stability is FSRS's own
  measure of memory strength, while the interval is a scheduling choice.
  """
  @spec mature?(WordState.t() | map(), number()) :: boolean()
  def mature?(%{stability: stability}, threshold \\ @maturity_days) do
    not is_nil(stability) and stability >= threshold
  end

  @doc """
  Whether a word is a massed-exposure case (§6.6): seen on at least 5 distinct
  pages at a density of at least 4 pages per day seen — a burst, not
  vocabulary the user is meeting over time. `days_seen` of 0 counts as one
  day (`max(days_seen, 1)`), so a same-day flood of 5+ pages qualifies.
  """
  @spec massed_exposure?(%{occurrences: number(), days_seen: number()}) :: boolean()
  def massed_exposure?(%{occurrences: occurrences, days_seen: days_seen}) do
    density = occurrences / max(days_seen, @massed_min_days)
    occurrences >= @massed_min_occurrences and density >= @massed_min_density
  end

  ## first review (state :new)

  # S0(G) = clamp(w[G-1], Smin, Smax);
  # D0(G) = clamp(w4 - e^(w5 * (G - 1)) + 1, Dmin, Dmax)
  @spec initial_review(WordState.t(), grade(), DateTime.t()) ::
          %{state: WordState.t(), interval_days: integer()}
  defp initial_review(%WordState{} = word_state, grade, now) do
    stability = initial_stability(grade)
    difficulty = initial_difficulty(grade)

    {state, interval_days, lapses} =
      if grade == @grade_again do
        # learning: due now, no interval to speak of
        {:learning, 0, 1}
      else
        {:review, success_interval(stability), 0}
      end

    next = %WordState{
      word_state
      | state: state,
        stability: stability,
        difficulty: difficulty,
        reps: 1,
        lapses: lapses,
        due_at: add_days(now, interval_days),
        last_reviewed_at: now
    }

    %{state: next, interval_days: interval_days}
  end

  @spec initial_stability(grade()) :: float()
  defp initial_stability(grade) do
    clamp(Enum.at(@weights, grade - 1), @s_min, @s_max)
  end

  @spec initial_difficulty(grade()) :: float()
  defp initial_difficulty(grade) do
    clamp(initial_difficulty_raw(grade), @d_min, @d_max)
  end

  defp initial_difficulty_raw(grade) do
    Enum.at(@weights, 4) - :math.exp(Enum.at(@weights, 5) * (grade - 1)) + 1
  end

  ## reviews of a word that has stability and difficulty (:learning, :review, :relearning)

  @spec reviewed(WordState.t(), grade(), DateTime.t()) ::
          %{state: WordState.t(), interval_days: integer()}
  defp reviewed(%WordState{} = word_state, grade, now) do
    elapsed_days = elapsed_days(word_state.last_reviewed_at, now)
    retrievability = retrievability(elapsed_days, word_state.stability)

    {state, stability, difficulty, interval_days} =
      transition(word_state, grade, elapsed_days, retrievability)

    next = %WordState{
      word_state
      | state: state,
        stability: stability,
        difficulty: difficulty,
        reps: word_state.reps + 1,
        lapses: word_state.lapses + lapse_delta(grade),
        due_at: add_days(now, interval_days),
        last_reviewed_at: now
    }

    %{state: next, interval_days: interval_days}
  end

  # same-day review: FSRS-6 replaces the long-term growth/lapse formulas with
  # the short-term stability formula
  @spec transition(WordState.t(), grade(), non_neg_integer(), float()) ::
          {1 | 2 | 3, float(), float(), non_neg_integer()}
  defp transition(%WordState{state: state, stability: s, difficulty: d}, grade, 0, _r) do
    stability = short_term_stability(s, grade)
    interval_days = if grade == @grade_again, do: 0, else: success_interval(stability)

    {next_state(state, grade), stability, next_difficulty(d, grade), interval_days}
  end

  # again after a day or more (lapse): relearning; post-lapse stability Sf is
  # capped at S / e^(w17 * w18), and the due date follows FSRS
  defp transition(
         %WordState{state: state, stability: s, difficulty: d},
         @grade_again,
         _elapsed,
         r
       ) do
    stability = post_lapse_stability(s, d, r)

    {next_state(state, @grade_again), stability, next_difficulty(d, @grade_again),
     success_interval(stability)}
  end

  # good/hard/easy after a day or more: the interval stretches by the FSRS
  # growth factor (hard and easy scaled by w15/w16), difficulty mean-reverts
  # toward D0(4)
  defp transition(%WordState{state: state, stability: s, difficulty: d}, grade, _elapsed, r)
       when grade >= @grade_hard do
    stability = post_success_stability(s, d, r, grade)
    {next_state(state, grade), stability, next_difficulty(d, grade), success_interval(stability)}
  end

  defp next_state(:learning, @grade_again), do: :learning
  defp next_state(_state, @grade_again), do: :relearning
  defp next_state(_state, _grade), do: :review

  @spec lapse_delta(grade()) :: 0 | 1
  defp lapse_delta(@grade_again), do: 1
  defp lapse_delta(_grade), do: 0

  # D' = D + ((10 - D) / 9) * (-w6 * (G - 3)); then mean reversion toward
  # D0(4): D'' = w7 * D0(4) + (1 - w7) * D'
  @spec next_difficulty(float(), grade()) :: float()
  defp next_difficulty(difficulty, grade) do
    delta_d = -Enum.at(@weights, 6) * (grade - @grade_good)
    shifted = difficulty + (10 - difficulty) / 9 * delta_d

    reverted =
      Enum.at(@weights, 7) * initial_difficulty_raw(@grade_easy) +
        (1 - Enum.at(@weights, 7)) * shifted

    clamp(reverted, @d_min, @d_max)
  end

  # Sf = min(w11 * D^-w12 * ((S + 1)^w13 - 1) * e^(w14 * (1 - R)),
  #          S / e^(w17 * w18)), clamped
  @spec post_lapse_stability(float(), float(), float()) :: float()
  defp post_lapse_stability(stability, difficulty, retrievability) do
    new_stability =
      Enum.at(@weights, 11) * :math.pow(difficulty, -Enum.at(@weights, 12)) *
        (:math.pow(stability + 1, Enum.at(@weights, 13)) - 1) *
        :math.exp(Enum.at(@weights, 14) * (1 - retrievability))

    stability_cap = stability / :math.exp(Enum.at(@weights, 17) * Enum.at(@weights, 18))

    min(new_stability, stability_cap)
    |> clamp(@s_min, @s_max)
  end

  # S' = S * e^(w17 * (G - 3 + w18)) * S^-w19, with the increment floored at
  # 1 for a successful (G >= 2) same-day review
  @spec short_term_stability(float(), grade()) :: float()
  defp short_term_stability(stability, grade) do
    increment =
      :math.exp(Enum.at(@weights, 17) * (grade - @grade_good + Enum.at(@weights, 18))) *
        :math.pow(stability, -Enum.at(@weights, 19))

    increment = if grade >= @grade_hard, do: max(increment, 1.0), else: increment

    (stability * increment)
    |> clamp(@s_min, @s_max)
  end

  # Sr = S * (1 + e^w8 * (11 - D) * S^-w9 * (e^(w10 * (1 - R)) - 1) * H_G * E_G),
  # clamped; H_G = w15 on hard, E_G = w16 on easy, 1 otherwise
  @spec post_success_stability(float(), float(), float(), grade()) :: float()
  defp post_success_stability(stability, difficulty, retrievability, grade) do
    hard_penalty = if grade == @grade_hard, do: Enum.at(@weights, 15), else: 1
    easy_bonus = if grade == @grade_easy, do: Enum.at(@weights, 16), else: 1

    f_d = 11 - difficulty
    f_g = hard_penalty * easy_bonus * :math.exp(Enum.at(@weights, 8))
    f_s = :math.pow(stability, -Enum.at(@weights, 9))
    f_r = :math.exp(Enum.at(@weights, 10) * (1 - retrievability)) - 1

    (stability * (1 + f_g * f_d * f_s * f_r))
    |> clamp(@s_min, @s_max)
  end

  @spec retrievability(non_neg_integer(), float()) :: float()
  defp retrievability(elapsed_days, stability) do
    :math.pow(1 + @factor * elapsed_days / max(stability, @s_min), @decay)
  end

  @spec success_interval(float()) :: integer()
  defp success_interval(stability) do
    max(1, round(interval_for(stability)))
  end

  # I(r, S) = S / FACTOR * (r ** (1/DECAY) - 1) — at r = 0.9 this is S
  @spec interval_for(float()) :: float()
  defp interval_for(stability) do
    (stability / @factor * (:math.pow(@desired_retention, 1 / @decay) - 1))
    |> clamp(0.0, @s_max)
  end

  @spec elapsed_days(DateTime.t() | nil, DateTime.t()) :: non_neg_integer()
  defp elapsed_days(nil, _now), do: 0

  defp elapsed_days(last_reviewed_at, now) do
    max(0, round(DateTime.diff(now, last_reviewed_at) / 86_400))
  end

  @spec add_days(DateTime.t(), number()) :: DateTime.t()
  defp add_days(now, days), do: DateTime.add(now, days * 86_400, :second)

  @spec clamp(number(), number(), number()) :: number()
  defp clamp(value, lo, hi), do: value |> min(hi) |> max(lo)
end
