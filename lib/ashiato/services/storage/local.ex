defmodule Ashiato.Storage.Local do
  @moduledoc """
  Filesystem-backed `Ashiato.Storage`.

  An object is a file under `root`; a key is validated and joined under it.
  Writes land via rename from a same-directory temporary file, so a reader sees
  either the previous object or the new one, never a partial file (rename within
  a filesystem is atomic).

  The root is application config, defaulting inside the already-gitignored
  `tmp/`:

      config :ashiato, Ashiato.Storage, root: "/path/to/volume/images"

  A symlink created between validation and the filesystem operation is not
  detected: a residual TOCTOU race remains.
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
  @doc """
  Writes `binary` at `key`, creating directories as needed.

  The write lands through a same-directory temporary file and a rename, so a concurrent
  reader sees either the previous object or the new one, never a partial image.
  """
  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, binary) do
    with {:ok, path} <- resolve_key(key),
         :ok <- File.mkdir_p(Path.dirname(path)),
         # re-check: mkdir_p may have created parents under a symlink that
         # appeared since the first check
         {:ok, path} <- resolve_key(key) do
      write_atomically(path, binary)
    end
  end

  @impl true
  @doc "Reads the object at `key`; a missing key is an error tuple, not a raise."
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(key) do
    with {:ok, path} <- resolve_key(key) do
      File.read(path)
    end
  end

  @doc """
  Returns a `file://` URL for `key`.

  This is **not a real pre-signature**: a local file needs no authorisation.
  `ttl_seconds` is part of the shared contract and is deliberately ignored.
  """
  @impl true
  @spec presigned_get(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def presigned_get(key, _ttl_seconds) do
    with {:ok, path} <- resolve_key(key) do
      {:ok, "file://" <> path}
    end
  end

  @impl true
  @doc "Deletes the object at `key`. Idempotent: an absent key is `:ok`."
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key) do
    with {:ok, path} <- resolve_key(key) do
      case File.rm(path) do
        :ok -> :ok
        # absent keys are already deleted: delete stays idempotent
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp resolve_key(key) do
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

  # A reader must never see a partial object: write to an exclusive temp file in
  # the target directory, then rename it over the key. The random name is opened
  # exclusively so neither a stale temp file nor a real key with that name is
  # truncated; a collision retries with a fresh name a bounded number of times.
  defp write_atomically(path, binary, retries \\ 10)

  defp write_atomically(_path, _binary, 0), do: {:error, :eexist}

  defp write_atomically(path, binary, retries) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    tmp = Path.join(Path.dirname(path), ".ashiato-tmp-" <> suffix)

    case :file.open(tmp, [:write, :exclusive, :binary, :raw]) do
      {:ok, fd} ->
        case write_and_close(fd, binary) do
          :ok ->
            case File.rename(tmp, path) do
              :ok ->
                :ok

              {:error, reason} ->
                File.rm(tmp)
                {:error, reason}
            end

          {:error, reason} ->
            File.rm(tmp)
            {:error, reason}
        end

      {:error, :eexist} ->
        write_atomically(path, binary, retries - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_and_close(fd, binary) do
    case :file.write(fd, binary) do
      :ok ->
        :file.close(fd)

      {:error, reason} ->
        :file.close(fd)
        {:error, reason}
    end
  end
end
