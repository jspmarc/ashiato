defmodule Ashiato.Repo.Migrations.AddFailureStreakToWordStates do
  use Ecto.Migration

  def up do
    alter table(:word_states) do
      add :failure_streak, :integer,
        null: false,
        default: 0,
        comment: "consecutive again grades; reset by any pass"
    end

    create constraint(:word_states, :word_states_failure_streak_valid,
             check: "failure_streak >= 0"
           )
  end

  def down do
    drop constraint(:word_states, :word_states_failure_streak_valid)

    alter table(:word_states) do
      remove :failure_streak
    end
  end
end
