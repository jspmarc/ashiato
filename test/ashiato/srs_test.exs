defmodule Ashiato.SrsTest do
  @moduledoc """
  Scheduler contract tests — pure functions, no DB.
  """

  use ExUnit.Case, async: true

  alias Ashiato.Srs
  alias Ashiato.WordStates

  @now ~U[2026-11-01 12:00:00Z]

  describe "final_interval/2" do
    test "caps bite only above the cap" do
      # occurrences >= 20 -> 60-day cap
      assert Srs.final_interval(59, 20) == 59
      assert Srs.final_interval(60, 25) == 60
      assert Srs.final_interval(61, 20) == 60

      # occurrences 8..19 -> 120-day cap
      assert Srs.final_interval(119, 8) == 119
      assert Srs.final_interval(120, 19) == 120
      assert Srs.final_interval(121, 12) == 120

      # occurrences 3..7 -> 240-day cap
      assert Srs.final_interval(239, 3) == 239
      assert Srs.final_interval(240, 7) == 240
      assert Srs.final_interval(241, 5) == 240
    end

    test "at most 2 occurrences never caps" do
      assert Srs.final_interval(400, 2) == 400
      assert Srs.final_interval(400, 1) == 400
      assert Srs.final_interval(400, 0) == 400
    end

    test "an interval of 0 (a lapse) stays 0 under every cap" do
      assert Srs.final_interval(0, 50) == 0
      assert Srs.final_interval(0, 0) == 0
    end
  end

  describe "mature?/2" do
    test "stability drives maturity even when the capped interval is below the threshold" do
      # capped to a 60-day due date, yet three weeks of forgetting already ran
      capped = %WordStates{
        state: 2,
        stability: 30.0,
        difficulty: 5.0,
        due_at: DateTime.add(@now, 60, :day)
      }

      assert Srs.mature?(capped)
      assert Srs.mature?(capped, 30)
      refute Srs.mature?(capped, 31)
    end

    test "a word below the threshold is not mature, however long its interval" do
      young = %WordStates{state: 2, stability: 20.9, due_at: DateTime.add(@now, 400, :day)}
      refute Srs.mature?(young)
      assert Srs.mature?(young, 20)
    end

    test "a never-reviewed word is not mature" do
      refute Srs.mature?(%WordStates{state: 0, stability: nil})
    end
  end

  describe "ghost?/1" do
    test "ghost detection at the boundaries" do
      # density = occurrences / max(days_seen, 1); ghost from 5 occurrences
      # and density >= 4
      refute Srs.ghost?(%{occurrences: 4, days_seen: 1})
      assert Srs.ghost?(%{occurrences: 5, days_seen: 1})
      refute Srs.ghost?(%{occurrences: 5, days_seen: 2})
      assert Srs.ghost?(%{occurrences: 8, days_seen: 2})
      refute Srs.ghost?(%{occurrences: 7, days_seen: 2})
      refute Srs.ghost?(%{occurrences: 5, days_seen: 3})
      assert Srs.ghost?(%{occurrences: 20, days_seen: 1})
    end

    test "no days seen counts as one day" do
      assert Srs.ghost?(%{occurrences: 5, days_seen: 0})
      refute Srs.ghost?(%{occurrences: 4, days_seen: 0})
    end
  end

  describe "grade/3 first review" do
    test "grade 1 seeds the word as learning, due now, with the lapse counted" do
      %{state: next, interval_days: interval} =
        Srs.grade(%WordStates{word_id: 7, state: 0, due_at: @now}, 1, @now)

      assert interval == 0
      assert next.word_id == 7
      assert next.state == 1
      assert next.reps == 1
      assert next.lapses == 1
      # S0(1) = w0; D0(1) = w4 + 2 * w5
      assert_in_delta next.stability, 0.4872, 1.0e-12
      assert_in_delta next.difficulty, 5.1618 + 2 * 1.2298, 1.0e-12
      assert next.due_at == @now
      assert next.last_reviewed_at == @now
    end

    test "grade 2 seeds the word as review, due the next day" do
      %{state: next, interval_days: interval} =
        Srs.grade(%WordStates{word_id: 7, state: 0, due_at: @now}, 2, @now)

      assert next.state == 2
      assert next.reps == 1
      assert next.lapses == 0
      # S0(2) = w1; D0(2) = w4 + w5
      assert_in_delta next.stability, 1.4003, 1.0e-12
      assert_in_delta next.difficulty, 5.1618 + 1.2298, 1.0e-12
      # I(0.9, S) is S: max(1, round(1.4003)) = 1 day
      assert interval == 1
      assert next.due_at == DateTime.add(@now, 1, :day)
      assert next.last_reviewed_at == @now
    end

    test "grade 3 seeds the word as review, due in four days" do
      %{state: next, interval_days: interval} =
        Srs.grade(%WordStates{word_id: 7, state: 0, due_at: @now}, 3, @now)

      assert next.state == 2
      assert next.reps == 1
      assert next.lapses == 0
      # S0(3) = w2; D0(3) = w4
      assert_in_delta next.stability, 3.7145, 1.0e-12
      assert_in_delta next.difficulty, 5.1618, 1.0e-12
      # I(0.9, S) is S: round(3.7145) = 4 days
      assert interval == 4
      assert next.due_at == DateTime.add(@now, 4, :day)
      assert next.last_reviewed_at == @now
    end

    test "grade 4 seeds the word as review, due after the S0 interval" do
      %{state: next, interval_days: interval} =
        Srs.grade(%WordStates{word_id: 7, state: 0, due_at: @now}, 4, @now)

      assert next.state == 2
      assert next.reps == 1
      assert next.lapses == 0
      # S0(4) = w3; D0(4) = w4 - w5
      assert_in_delta next.stability, 13.8206, 1.0e-12
      assert_in_delta next.difficulty, 5.1618 - 1.2298, 1.0e-12
      # I(0.9, S) is S: round(13.8206) = 14 days
      assert interval == 14
      assert next.due_at == DateTime.add(@now, 14, :day)
      assert next.last_reviewed_at == @now
    end

    test "grades 2 and 3 seed review with their own S0/D0" do
      # S0(G) = w[G-1]; D0(G) = w4 - (G - 3) * w5
      for {grade, s0, d0} <- [{2, 1.4003, 5.1618 + 1.2298}, {3, 3.7145, 5.1618}] do
        %{state: next, interval_days: interval} =
          Srs.grade(%WordStates{word_id: 7, state: 0, due_at: @now}, grade, @now)

        assert next.state == 2
        assert next.reps == 1
        assert next.lapses == 0
        assert_in_delta next.stability, s0, 1.0e-12
        assert_in_delta next.difficulty, d0, 1.0e-12
        # I(0.9, S) is S, floored at a whole day
        assert interval == max(1, round(s0))
        assert next.due_at == DateTime.add(@now, interval, :day)
        assert next.last_reviewed_at == @now
      end
    end
  end

  describe "grade/3 lapses" do
    test "a lapse from review drops to relearning, resets the interval, counts the lapse" do
      state = %WordStates{
        word_id: 3,
        state: 2,
        stability: 40.0,
        difficulty: 5.0,
        reps: 5,
        lapses: 0,
        last_reviewed_at: DateTime.add(@now, -40, :day)
      }

      %{state: next, interval_days: interval} = Srs.grade(state, 1, @now)

      assert interval == 0
      assert next.state == 3
      assert next.due_at == @now
      assert next.reps == 6
      assert next.lapses == 1
      # Sf never exceeds the stability that was just failed
      assert next.stability < state.stability
      assert next.last_reviewed_at == @now
    end

    test "failing a learning word resets it to the seed values and stays in learning" do
      state = %WordStates{
        word_id: 1,
        state: 1,
        stability: 0.4872,
        difficulty: 7.6214,
        reps: 1,
        lapses: 1,
        last_reviewed_at: DateTime.add(@now, -1, :day)
      }

      %{state: next, interval_days: interval} = Srs.grade(state, 1, @now)

      assert interval == 0
      assert next.state == 1
      assert next.due_at == @now
      assert next.reps == 2
      assert next.lapses == 2
      assert_in_delta next.stability, 0.4872, 1.0e-12
      assert_in_delta next.difficulty, 7.6214, 1.0e-12
    end

    test "failing a relearning word keeps it there with the interval reset" do
      state = %WordStates{
        word_id: 2,
        state: 3,
        stability: 5.0,
        difficulty: 6.0,
        reps: 7,
        lapses: 2,
        last_reviewed_at: DateTime.add(@now, -5, :day)
      }

      %{state: next, interval_days: interval} = Srs.grade(state, 1, @now)

      assert interval == 0
      assert next.state == 3
      assert next.due_at == @now
      assert next.reps == 8
      assert next.lapses == 3
      assert next.stability < state.stability
    end
  end

  describe "grade/3 passes" do
    test "passing a learning word graduates it to review" do
      state = %WordStates{
        word_id: 1,
        state: 1,
        stability: 0.4872,
        difficulty: 7.6214,
        reps: 1,
        lapses: 1,
        last_reviewed_at: @now
      }

      %{state: next, interval_days: interval} = Srs.grade(state, 2, @now)

      assert next.state == 2
      assert next.reps == 2
      assert next.lapses == 1
      # same-moment review: R = 1, the growth term is empty and S stays
      assert_in_delta next.stability, 0.4872, 1.0e-9
      assert interval == 1
      assert next.due_at == DateTime.add(@now, 1, :day)
    end

    test "passing a relearning word returns it to review" do
      state = %WordStates{
        word_id: 2,
        state: 3,
        stability: 3.0,
        difficulty: 7.0,
        reps: 6,
        lapses: 1,
        last_reviewed_at: @now
      }

      %{state: next, interval_days: interval} = Srs.grade(state, 3, @now)

      assert next.state == 2
      assert next.reps == 7
      assert next.lapses == 1
      assert_in_delta next.stability, 3.0, 1.0e-9
      assert interval == 3
      assert next.due_at == DateTime.add(@now, 3, :day)
    end

    test "a good review from review grows stability and schedules the interval" do
      state = %WordStates{
        word_id: 4,
        state: 2,
        stability: 10.0,
        difficulty: 5.0,
        reps: 3,
        lapses: 0,
        last_reviewed_at: DateTime.add(@now, -10, :day)
      }

      %{state: next, interval_days: interval} = Srs.grade(state, 3, @now)

      assert next.state == 2
      assert next.reps == 4
      assert next.lapses == 0
      assert next.stability > state.stability
      # the interval solves R(t, S') = 0.9, which is S' in whole days
      assert interval == max(1, round(next.stability))
      assert next.due_at == DateTime.add(@now, interval, :day)
    end

    test "hard grows stability less than good, easy more" do
      state = %WordStates{
        word_id: 4,
        state: 2,
        stability: 10.0,
        difficulty: 5.0,
        reps: 3,
        lapses: 0,
        last_reviewed_at: DateTime.add(@now, -10, :day)
      }

      hard = Srs.grade(state, 2, @now)
      good = Srs.grade(state, 3, @now)
      easy = Srs.grade(state, 4, @now)

      assert hard.state.stability < good.state.stability
      assert good.state.stability < easy.state.stability
      assert easy.state.stability > state.stability
    end
  end
end
