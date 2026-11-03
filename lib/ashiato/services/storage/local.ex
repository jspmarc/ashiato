defmodule Ashiato.Storage.Local do
  @moduledoc """
  Filesystem-backed `Ashiato.Storage`: a shared-volume directory.

  The OCR client's `{:path, ...}` locator and the `{:url, ...}` locator both
  work here because the pod's containers mount the same volume — see §7.3 of
  `docs/requirements.md`.

  Writes land via rename from a same-directory temporary file, so a reader can
  never observe a half-written image (rename within a filesystem is atomic).

  The root is application config, defaulting inside the already-gitignored
  `tmp/`:

      config :ashiato, Ashiato.Storage, root: "/path/to/volume/images"
  """

  @behaviour Ashiato.Storage

  @doc """
  The configured root directory, used lazily so tests can point it at a
  per-test directory without touching `config/`.
  """
  @spec root() :: String.t()
  def root do
    Application.get_env(:ashiato, Ashiato.Storage, [])[:root] ||
      Path.join(File.cwd!(), "tmp/storage")
  end

  @impl true
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, binary) do
    with {:ok, path} <- resolve(key),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      write_atomically(path, binary)
    end
  end

  @impl true
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(key) do
    with {:ok, path} <- resolve(key) do
      File.read(path)
    end
  end

  @doc """
  Returns a `file://` URL the OCR locator can carry.

  This is **not a real pre-signature** — a local file needs no authorisation —
  but it keeps the `presigned_get` contract identical for the later S3 store.
  `ttl_seconds` is part of the shared contract and is deliberately ignored.
  """
  @impl true
  @spec presigned_get(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_get(key, _ttl_seconds) do
    with {:ok, path} <- resolve(key) do
      {:ok, "file://" <> path}
    end
  end

  @impl true
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    with {:ok, path} <- resolve(key) do
      case File.rm(path) do
        :ok -> :ok
        # absent keys are already deleted: delete stays idempotent
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve(key) do
    if Ashiato.Storage.valid_key?(key) do
      root = Path.expand(root())
      path = Path.expand(Path.join(root, key))

      cond do
        # the lexical check resolves `..` the key may still carry
        not String.starts_with?(path, root <> "/") -> {:error, :invalid_key}
        escapes_via_symlink?(root, path) -> {:error, :invalid_key}
        true -> {:ok, path}
      end
    else
      {:error, :invalid_key}
    end
  end

  # A lexical check cannot see a symlink that already exists inside the root: `link/secret`
  # passes it and reads, overwrites or deletes a file outside. Rather than resolve targets
  # (Elixir has no realpath), the store refuses to traverse a symlink at all — an image
  # store has no legitimate use for one, and refusing is the smaller rule to reason about.
  defp escapes_via_symlink?(root, path) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn part, dir ->
      next = Path.join(dir, part)

      case :file.read_link(next) do
        {:ok, _target} -> {:halt, :symlink}
        {:error, _not_a_link_or_absent} -> {:cont, next}
      end
    end)
    |> Kernel.==(:symlink)
  end

  defp write_atomically(path, binary) do
    # same directory as the target so the rename never crosses a filesystem
    tmp = Path.join(Path.dirname(path), ".ashiato-tmp-#{:erlang.unique_integer([:positive])}")

    with :ok <- File.write(tmp, binary),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        {:error, reason}
    end
  end
end
