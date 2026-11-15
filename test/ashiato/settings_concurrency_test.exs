defmodule Ashiato.SettingsConcurrencyTest do
  @moduledoc """
  Proves the secret-classification serialisation on PostgreSQL: a writer that
  omits `:secret` cannot read the row while a concurrent `secret: true` write
  is uncommitted, so it can never overwrite a secret row as plaintext for
  `all/1` to expose.

  Like the ledger concurrency cases, the shared sandbox cannot show this —
  `start_owner!(shared: true)` checks out one connection, so two tasks would
  serialise on it inside one transaction. Here every put runs in
  `Sandbox.unboxed_run/2` on its own connection and really commits; committed
  rows are deleted in `on_exit`, so reruns are idempotent.
  """

  use ExUnit.Case, async: false

  @moduletag :postgres

  import Ecto.Query

  alias Ashiato.{Repo, Settings}
  alias Ashiato.Schemas.{Setting, User}

  test "a concurrent re-put without the flag cannot declassify an uncommitted secret" do
    user = Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Repo.insert!(%User{}) end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(s in Setting, where: s.user_id == ^user.id))
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)
    end)

    parent = self()

    task_a =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            # the secret writer holds the users row while its write is uncommitted
            Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))

            assert {:ok, _} =
                     Settings.put(user.id, "openai_api_key", "sk-secret", secret: true)

            send(parent, :a_uncommitted)

            receive do
              :commit -> :ok
            end
          end)
        end)
      end)

    assert_receive :a_uncommitted, 5_000

    task_b =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:b_backend_pid, backend_pid})

          Settings.put(user.id, "openai_api_key", "sk-plain")
        end)
      end)

    assert_receive {:b_backend_pid, backend_pid}, 5_000

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      wait_until_blocked_on_lock(backend_pid)
    end)

    send(task_a.pid, :commit)

    assert {:ok, %{secret: true}} = Task.await(task_b, 30_000)
    Task.await(task_a, 30_000)

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      row = Repo.get_by!(Setting, user_id: user.id, key: "openai_api_key")
      assert row.secret
      refute row.value =~ "sk-plain"
      assert Settings.get(user.id, "openai_api_key") == "sk-plain"
      assert Settings.all(user.id)["openai_api_key"] == :redacted
    end)
  end

  # The parent may only release the secret writer once the plaintext writer is
  # genuinely waiting on the `users` row lock; otherwise the plaintext writer
  # could classify after the commit and the test would pass without the lock.
  defp wait_until_blocked_on_lock(pid) do
    poll_until_blocked(pid, System.monotonic_time(:millisecond) + 2_000)
  end

  defp poll_until_blocked(pid, deadline) do
    %{rows: [[count]]} =
      Repo.query!("SELECT count(*) FROM pg_locks WHERE pid = $1 AND NOT granted", [pid])

    blocked? = count > 0

    if blocked? or System.monotonic_time(:millisecond) >= deadline do
      blocked? ||
        flunk(
          "task B never blocked on the users row lock: no ungranted lock for pid #{pid} within 2s"
        )
    else
      Process.sleep(5)
      poll_until_blocked(pid, deadline)
    end
  end
end
