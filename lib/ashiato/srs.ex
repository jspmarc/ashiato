defmodule Ashiato.Srs do
  @moduledoc """
  The FSRS-4.5 scheduler as pure functions over `Ashiato.WordStates`: no Repo,
  no clock, no IO. It computes the next state and the uncapped interval from
  review grades alone; `Ashiato.Ledger` applies the interval cap afterwards,
  which clamps the scheduled interval but never the stability.

  Sources (FSRS-4.5, 17 weights):

    * Formulas — ts-fsrs docs, reviewed against the awesome-fsrs wiki:
      https://open-spaced-repetition.github.io/ts-fsrs/guide/model/fsrs-4dot5.md
    * Default parameters `w0..w16` — awesome-fsrs wiki, "FSRS-4.5" section:
      https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm

  Stability is clamped to 0.001..36500.0 days (100 years, as fsrs-rs does) and
  difficulty to 1.0..10.0; states are 0..3 (new / learning / review /
  relearning). This app has no minute-scale learning steps — reviews are real,
  days-apart events — so a first "again" parks the word in learning with the
  interval reset to 0 rather than scheduling a sub-day step.

  The curves:

      R(t, S) = (1 + FACTOR * t / S) ** DECAY          # retrievability
      I(r, S) = S / FACTOR * (r ** (1/DECAY) - 1)      # interval for retention r

  with DECAY = -0.5 and FACTOR = 19/81, so `I(0.9, S)` is exactly `S`: at the
  default desired retention of 0.9, a day count is a day count.
  """

  alias Ashiato.WordStates

  @typedoc "The FSRS grade: 1 = again, 2 = hard, 3 = good, 4 = easy."
  @type grade :: 1..4

  # FSRS-4.5 default weights w0..w16 (awesome-fsrs wiki, "FSRS-4.5" section):
  # w0..w3 initial stability per grade, w4..w5 initial difficulty,
  # w6..w7 difficulty updates and mean reversion, w8..w10 post-success growth,
  # w11..w14 post-lapse stability, w15 hard penalty, w16 easy bonus.
  @weights [
    0.4872,
    1.4003,
    3.7145,
    13.8206,
    5.1618,
    1.2298,
    0.8975,
    0.031,
    1.6474,
    0.1367,
    1.0461,
    2.1072,
    0.0793,
    0.3246,
    1.587,
    0.2272,
    2.8755
  ]

  @decay -0.5
  @factor 19 / 81

  @s_min 0.001
  @s_max 36500.0
  @d_min 1.0
  @d_max 10.0

  @desired_retention 0.9

  @doc """
  Grades one review and returns the next FSRS state.

  `word_state` is the current `%Ashiato.WordStates{}`. State 0 means the word
  was never reviewed; states 1..3 carry `stability`/`difficulty`, and
  `elapsed time` since `last_reviewed_at` feeds the retrievability of this
  review. `grade` is the FSRS grade: 1 again, 2 hard, 3 good, 4 easy.

  Returns `%{state: %Ashiato.WordStates{}, interval_days: integer()}` — the
  updated struct (same `word_id`, new state/stability/difficulty/reps/lapses,
  `last_reviewed_at = now`, `due_at = now + interval_days`) plus the integer
  FSRS interval that `due_at` was computed from, uncapped.
  """
  @spec grade(WordStates.t(), 1..4, DateTime.t()) :: %{
          state: WordStates.t(),
          interval_days: integer()
        }
  def grade(%WordStates{} = word_state, grade, %DateTime{} = now) when grade in 1..4 do
    if word_state.state == 0 do
      initial_review(word_state, grade, now)
    else
      reviewed(word_state, grade, now)
    end
  end

  @doc """
  Interval cap for a word's encounter band: 60 days at 20+ distinct confirmed
  encounter pages, 120 at 8..19, 240 at 3..7, and `nil` (uncapped) at 2 or
  fewer.
  """
  @spec cap_for_band(integer()) :: 60 | 120 | 240 | nil
  def cap_for_band(occurrences) when occurrences >= 20, do: 60
  def cap_for_band(occurrences) when occurrences >= 8, do: 120
  def cap_for_band(occurrences) when occurrences >= 3, do: 240
  def cap_for_band(_occurrences), do: nil

  @doc """
  The interval a review may actually schedule: the FSRS interval clamped by
  the word's encounter band (`cap_for_band/1`). Words with 2 or fewer
  encounters are uncapped.
  """
  @spec final_interval(integer(), integer()) :: integer()
  def final_interval(fsrs_interval_days, occurrences) do
    case cap_for_band(occurrences) do
      nil -> fsrs_interval_days
      cap -> min(fsrs_interval_days, cap)
    end
  end

  @doc """
  Whether a word has crossed `threshold` days of stability (default 21).

  Maturity is decided by stability, never by the scheduled interval: heavy
  words can be due again in days while their stability says they know the
  word.
  """
  @spec mature?(WordStates.t() | map(), number()) :: boolean()
  def mature?(%{stability: stability}, threshold \\ 21) do
    not is_nil(stability) and stability >= threshold
  end

  @doc """
  Whether a word is a ghost — massed exposure, not vocabulary met over time:
  seen on at least 5 distinct pages at a density of at least 4 pages per day
  seen. `days_seen` of 0 counts as one day (`max(days_seen, 1)`), so a
  same-day flood of 5+ pages is a ghost.
  """
  @spec ghost?(%{occurrences: number(), days_seen: number()}) :: boolean()
  def ghost?(%{occurrences: occurrences, days_seen: days_seen}) do
    density = occurrences / max(days_seen, 1)
    occurrences >= 5 and density >= 4
  end

  ## first review (state 0)

  # S0(G) = clamp(w[G-1], Smin, Smax); D0(G) = clamp(w4 - (G-3) * w5, Dmin, Dmax)
  @spec initial_review(WordStates.t(), grade(), DateTime.t()) ::
          %{state: WordStates.t(), interval_days: integer()}
  defp initial_review(%WordStates{} = word_state, grade, now) do
    stability = clamp(Enum.at(@weights, grade - 1), @s_min, @s_max)
    difficulty = initial_difficulty(grade)

    {state, interval_days, lapses} =
      if grade == 1 do
        # learning: due now, no interval to speak of
        {1, 0, 1}
      else
        {2, success_interval(stability), 0}
      end

    next = %WordStates{
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

  defp initial_difficulty(grade) do
    clamp(Enum.at(@weights, 4) - (grade - 3) * Enum.at(@weights, 5), @d_min, @d_max)
  end

  ## reviews of a word that has stability and difficulty (states 1..3)

  @spec reviewed(WordStates.t(), grade(), DateTime.t()) ::
          %{state: WordStates.t(), interval_days: integer()}
  defp reviewed(%WordStates{} = word_state, grade, now) do
    retrievability =
      retrievability(elapsed_days(word_state.last_reviewed_at, now), word_state.stability)

    {state, stability, difficulty, interval_days} = transition(word_state, grade, retrievability)

    next = %WordStates{
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

  # state 1 (learning), again: the word is re-introduced from its initial
  # values rather than computed from the curve — this app has no learning
  # steps to forget into
  defp transition(%WordStates{state: 1}, 1, _retrievability) do
    {1, clamp(Enum.at(@weights, 0), @s_min, @s_max), initial_difficulty(1), 0}
  end

  # states 2/3, again (lapse): relearning; post-lapse stability Sf never
  # exceeds the stability the word just failed to hold
  defp transition(%WordStates{stability: s, difficulty: d}, 1, r) do
    {3, post_lapse_stability(s, d, r), next_difficulty(d, 1), 0}
  end

  # any state, good/hard/easy: the interval stretches by the FSRS growth
  # factor (hard and easy scaled by w15/w16), difficulty mean-reverts toward
  # D0(3) = w4
  defp transition(%WordStates{stability: s, difficulty: d}, grade, r) when grade >= 2 do
    stability = post_success_stability(s, d, r, grade)
    {2, stability, next_difficulty(d, grade), success_interval(stability)}
  end

  defp lapse_delta(1), do: 1
  defp lapse_delta(_grade), do: 0

  # D' = clamp(w7 * w4 + (1 - w7) * (D - w6 * (G - 3)), Dmin, Dmax) — mean
  # reversion toward D0(3) = w4 after the linear shift
  defp next_difficulty(difficulty, grade) do
    reverted =
      Enum.at(@weights, 7) * Enum.at(@weights, 4) +
        (1 - Enum.at(@weights, 7)) * (difficulty - Enum.at(@weights, 6) * (grade - 3))

    clamp(reverted, @d_min, @d_max)
  end

  # Sf = min(w11 * D^-w12 * ((S + 1)^w13 - 1) * e^(w14 * (1 - R)), S), clamped
  defp post_lapse_stability(stability, difficulty, retrievability) do
    min(
      Enum.at(@weights, 11) * :math.pow(difficulty, -Enum.at(@weights, 12)) *
        (:math.pow(stability + 1, Enum.at(@weights, 13)) - 1) *
        :math.exp(Enum.at(@weights, 14) * (1 - retrievability)),
      stability
    )
    |> clamp(@s_min, @s_max)
  end

  # Sr = S * (1 + e^w8 * (11 - D) * S^-w9 * (e^(w10 * (1 - R)) - 1) * H_G * E_G),
  # clamped; H_G = w15 on hard, E_G = w16 on easy, 1 otherwise
  defp post_success_stability(stability, difficulty, retrievability, grade) do
    hard_penalty = if grade == 2, do: Enum.at(@weights, 15), else: 1
    easy_bonus = if grade == 4, do: Enum.at(@weights, 16), else: 1

    (stability *
       (1 +
          :math.exp(Enum.at(@weights, 8)) * (11 - difficulty) *
            :math.pow(stability, -Enum.at(@weights, 9)) *
            (:math.exp(Enum.at(@weights, 10) * (1 - retrievability)) - 1) * hard_penalty *
            easy_bonus))
    |> clamp(@s_min, @s_max)
  end

  defp retrievability(elapsed_days, stability) do
    :math.pow(1 + @factor * elapsed_days / stability, @decay)
  end

  defp success_interval(stability) do
    max(1, round(interval_for(stability)))
  end

  # I(r, S) = S / FACTOR * (r ** (1/DECAY) - 1) — at r = 0.9 this is S
  defp interval_for(stability) do
    stability / @factor * (:math.pow(@desired_retention, 1 / @decay) - 1)
  end

  defp elapsed_days(nil, _now), do: 0.0

  defp elapsed_days(last_reviewed_at, now) do
    max(0.0, DateTime.diff(now, last_reviewed_at) / 86_400.0)
  end

  defp add_days(now, days), do: DateTime.add(now, days * 86_400, :second)

  defp clamp(value, lo, hi), do: value |> min(hi) |> max(lo)
end
