defmodule Ashiato.Settings do
  @moduledoc """
  The typed accessor over the per-user `settings` key-value table, and the only
  module that knows settings are key-value — everything else calls this context
  and works with typed values.

  Values are JSON-encoded in the `value` column, so a boolean reads back as a
  boolean and a list as a list. Rows marked `secret: true` are encrypted at
  rest with a key derived deterministically from `SECRET_KEY_BASE`, and the
  plaintext of a secret never reaches a log or an error report.

  The module is also the behaviour of the settings boundary: `impl/0` returns
  the configured implementation (defaulting to this one), so callers use
  `impl().get/3` and swap in a fake in tests without naming a concrete module.
  The capability helpers read their inputs through `impl/0` for the same
  reason, which is what lets the gates be driven against the fake.
  """

  import Ecto.Query
  require Logger

  alias Ashiato.Repo
  alias Ashiato.Schemas.Setting
  alias Ashiato.Schemas.User
  alias Ashiato.Utils

  @callback get(integer(), String.t(), term()) :: term()
  @callback put(integer(), String.t(), term(), keyword()) ::
              {:ok, Setting.t()}
              | {:error, Ecto.Changeset.t() | :not_encodable | :secret_key_base_missing}
  @callback all(integer()) :: %{optional(String.t()) => term()}
  @callback credential(integer(), String.t()) :: String.t() | nil

  @key_salt "ashiato settings"

  # Built-in defaults: a missing row must never force a caller to special-case nil.
  @defaults %{
    "ai_features_enabled" => false,
    "translation_enabled" => false,
    "translation_provider" => "google_free",
    "min_encounters" => 2,
    "new_cards_per_day" => 10,
    "maturity_threshold_days" => 21
  }

  @doc "Built-in defaults for keys without a stored row."
  @spec defaults() :: %{String.t() => term()}
  def defaults(), do: @defaults

  @doc """
  Returns the configured implementation of the `get/3`, `put/4` and `all/1`
  callbacks from application config (`config :ashiato, :settings, MyImpl`),
  defaulting to this module — the repo-backed accessor. Callers use
  `impl().get/3` and never name a concrete module.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:ashiato, :settings, __MODULE__)

  @doc """
  Reads one setting as a decoded value. A missing row falls back to the
  built-in default for known keys, and to `default` for any other key.

  A secret row is decrypted first; if authentication fails the default is
  returned and the failure is logged without the value.
  """
  @spec get(integer(), String.t(), term()) :: term()
  def get(user_id, key, default \\ nil) do
    fallback = Map.get(defaults(), key, default)

    case Repo.get_by(Setting, user_id: user_id, key: key) do
      nil ->
        fallback

      %Setting{secret: true, value: cipher} ->
        decrypt(cipher, key, fallback)

      %Setting{value: json} ->
        decode(json, key, fallback)
    end
  end

  @doc """
  Stores one setting, JSON-encoded, upserting on `(user_id, key)`: a second
  `put` replaces the row and never raises the unique constraint.

  `opts` decides the secret classification:

  - `secret: true` stores the value encrypted at rest;
  - `secret: false` declassifies — an existing secret row is rewritten in the
    clear;
  - omitting `:secret` preserves the existing row's classification, so
    re-storing a secret without the flag stays encrypted, and a new row is
    stored in the clear.

  `user_id` is set on the struct, never cast.

  The classification read and the upsert run in one transaction; on PostgreSQL
  the owning `users` row is locked first, so a writer that omits `:secret`
  cannot classify against an uncommitted `secret: true` write and rewrite the
  row as plaintext.
  """
  @spec put(integer(), String.t(), term(), keyword()) ::
          {:ok, Setting.t()}
          | {:error, Ecto.Changeset.t() | :not_encodable | :secret_key_base_missing}
  def put(user_id, key, value, opts \\ []) do
    Repo.transaction(fn ->
      lock_user_row(user_id)

      secret? =
        case Keyword.fetch(opts, :secret) do
          {:ok, explicit} -> explicit
          :error -> existing_secret?(user_id, key)
        end

      with {:ok, stored} <- encode_value(value, secret?),
           {:ok, row} <- upsert(user_id, key, stored, secret?) do
        row
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Omitting `:secret` means "keep whatever this row already is": a re-put of an
  # existing secret must not silently store the plaintext, and a brand-new key
  # is not a secret unless the caller says so.
  defp existing_secret?(user_id, key) do
    case Repo.get_by(Setting, user_id: user_id, key: key) do
      nil -> false
      %Setting{secret: secret?} -> secret?
    end
  end

  # The users row is the serialisation point for the classification read: it
  # always exists for a stored setting, and locking it makes a concurrent
  # `secret: true` write commit before the read, so the flag can never be read
  # as "absent/non-secret" and the row rewritten as plaintext. SQLite has no
  # row locks (`lock:` raises "locks are not supported by SQLite3") and its
  # single-writer engine serialises writes anyway, so it keeps the plain fetch.
  @spec lock_user_row(integer()) :: :ok
  defp lock_user_row(user_id) do
    if Application.fetch_env!(:ashiato, :ecto_adapter) == Ecto.Adapters.Postgres do
      from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
      |> Repo.one()
    end

    :ok
  end

  # Encode first, encrypt second: a pid, tuple or struct cannot be JSON, and a crash here
  # would be an ArgumentError out of the settings UI rather than an error it can show.
  @spec encode_value(term(), boolean()) ::
          {:ok, String.t()} | {:error, :not_encodable | :secret_key_base_missing}
  defp encode_value(value, secret?) do
    case Jason.encode(value) do
      {:ok, json} when secret? ->
        encrypt(json)

      {:ok, json} ->
        {:ok, json}

      {:error, _reason} ->
        {:error, :not_encodable}
    end
  end

  defp upsert(user_id, key, stored, secret?) do
    now = Utils.utc_now()

    changeset =
      %Setting{user_id: user_id, key: key}
      |> Ecto.Changeset.change(value: stored, secret: secret?)
      |> Ecto.Changeset.validate_required([:user_id])

    # SQLite reports a foreign-key violation with a nil constraint name, so
    # `foreign_key_constraint/3` cannot map it; translate the raise instead.
    try do
      Repo.insert(changeset,
        on_conflict: [set: [value: stored, secret: secret?, updated_at: now]],
        conflict_target: [:user_id, :key]
      )
    rescue
      error in Ecto.ConstraintError ->
        Logger.warning("setting #{key} cannot be stored: #{error.type} failed")
        {:error, Ecto.Changeset.add_error(changeset, :user_id, "does not exist")}
    end
  end

  @doc """
  Reads every setting of a user as `%{"key" => decoded value}`.

  Secret values come back as `:redacted`: a bulk read must never spread
  plaintext, and the settings UI needs readiness (the key exists), not the
  value — `get/3` is the deliberate path to a secret.
  """
  @spec all(integer()) :: %{optional(String.t()) => term()}
  def all(user_id) do
    from(s in Setting, where: s.user_id == ^user_id)
    |> Repo.all()
    |> Map.new(fn
      %Setting{key: key, secret: true} -> {key, :redacted}
      %Setting{key: key, value: json} -> {key, decode(json, key, nil)}
    end)
  end

  @doc """
  The AI gate: `ai_features_enabled` is on AND a non-empty
  `OPENAI_API_KEY` exists — settings row first, then `System.get_env/1`. An
  empty key disables the feature even with the switch on, so affordances hide
  instead of failing at call time.
  """
  @spec ai_capable?(integer()) :: boolean()
  def ai_capable?(user_id) do
    impl().get(user_id, "ai_features_enabled", false) === true and
      credential?(user_id, "OPENAI_API_KEY")
  end

  @doc """
  The translation gate: `translation_enabled` is on AND the selected
  `translation_provider` is configured. `google_free` needs nothing, `off` is
  never capable, and the other providers each need their key.
  """
  @spec translate_capable?(integer()) :: boolean()
  def translate_capable?(user_id) do
    impl().get(user_id, "translation_enabled", false) === true and
      provider_configured?(user_id, impl().get(user_id, "translation_provider", "google_free"))
  end

  # ── capability helpers ──────────────────────────────────────────────────────

  defp provider_configured?(_user_id, "google_free"), do: true
  defp provider_configured?(_user_id, "off"), do: false
  defp provider_configured?(user_id, "deepl"), do: credential?(user_id, "deepl_api_key")

  defp provider_configured?(user_id, "google_cloud"),
    do: credential?(user_id, "google_cloud_api_key")

  defp provider_configured?(user_id, "llm"), do: credential?(user_id, "OPENAI_API_KEY")
  defp provider_configured?(_user_id, _unknown), do: false

  @doc """
  The credential for `key`: the stored row wins and the environment variable
  named by the uppercase key (`OPENAI_API_KEY`, `DEEPL_API_KEY`,
  `GOOGLE_CLOUD_API_KEY`) is the fallback. An explicitly empty stored value —
  an empty string or JSON `null` — blocks the fallback, so a cleared key
  disables the capability even when the environment still holds one. A secret
  row is decrypted first, and a resolved value that is empty or not a binary
  is `nil`.
  """
  @spec credential(integer(), String.t()) :: String.t() | nil
  def credential(user_id, key) do
    value =
      case Repo.get_by(Setting, user_id: user_id, key: key) do
        nil -> System.get_env(String.upcase(key))
        %Setting{secret: true, value: cipher} -> decrypt(cipher, key, nil)
        %Setting{value: json} -> decode(json, key, nil)
      end

    if is_binary(value) and value != "", do: value
  end

  defp credential?(user_id, key), do: impl().credential(user_id, key) != nil

  # ── storage ─────────────────────────────────────────────────────────────────

  # the value column is nullable, so a hand-written or half-migrated row can hold NULL
  defp decode(nil, key, fallback) do
    Logger.warning("setting #{key} has no value; returning default")
    fallback
  end

  defp decode(json, key, fallback) do
    case Jason.decode(json) do
      {:ok, value} ->
        value

      {:error, _} ->
        Logger.warning("setting #{key} is not valid JSON; returning default")
        fallback
    end
  end

  defp encrypt(plain_json) do
    try do
      key = derived_key()
      {:ok, Plug.Crypto.MessageEncryptor.encrypt(plain_json, key, key)}
    rescue
      ArgumentError ->
        Logger.warning("setting encryption failed: SECRET_KEY_BASE missing")
        {:error, :secret_key_base_missing}
    end
  end

  # A read must never raise: the ingest pipeline reads settings. A missing SECRET_KEY_BASE
  # therefore degrades the read to the default and is logged without the value; only the
  # write path refuses (storing a secret unencrypted would be worse than failing).
  defp decrypt(cipher, key, fallback) do
    crypto_key = derived_key()

    case Plug.Crypto.MessageEncryptor.decrypt(cipher, crypto_key, crypto_key) do
      {:ok, plain} ->
        decode(plain, key, fallback)

      :error ->
        Logger.warning("setting #{key} failed authentication; returning default")
        fallback
    end
  rescue
    error in ArgumentError ->
      Logger.warning("setting #{key} cannot be decrypted (#{Exception.message(error)})")
      fallback
  end

  # Deterministic derivation: the same SECRET_KEY_BASE yields the same
  # 32-byte key on every boot, so no key column is needed. A missing
  # SECRET_KEY_BASE raises here rather than storing plaintext.
  defp derived_key do
    Plug.Crypto.KeyGenerator.generate(secret_key_base(), @key_salt,
      iterations: 1000,
      length: 32
    )
  end

  defp secret_key_base do
    case Application.get_env(:ashiato, AshiatoWeb.Endpoint) do
      nil ->
        raise ArgumentError,
              "The Ashiato endpoint config is missing: SECRET_KEY_BASE cannot be read"

      config ->
        case config[:secret_key_base] do
          key when is_binary(key) and key != "" ->
            key

          _ ->
            raise ArgumentError,
                  "SECRET_KEY_BASE is missing: refusing to store a secret unencrypted"
        end
    end
  end
end
