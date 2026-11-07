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
  alias Ashiato.Utils

  @callback get(integer(), String.t(), term()) :: term()
  @callback put(integer(), String.t(), term(), keyword()) ::
              {:ok, Setting.t()}
              | {:error, Ecto.Changeset.t() | :not_encodable | :secret_key_base_missing}
  @callback all(integer()) :: %{optional(String.t()) => term()}

  @secret_salt "ashiato settings"

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
  `put` replaces the row and never raises the unique constraint. `opts` may
  carry `secret: true` to store the value encrypted at rest. `user_id` is set
  on the struct, never cast.
  """
  @spec put(integer(), String.t(), term(), keyword()) ::
          {:ok, Setting.t()}
          | {:error, Ecto.Changeset.t() | :not_encodable | :secret_key_base_missing}
  def put(user_id, key, value, opts \\ []) do
    secret? = Keyword.get(opts, :secret, false)

    with {:ok, stored} <- store_value(value, secret?) do
      upsert(user_id, key, stored, secret?)
    end
  end

  # Encode first, encrypt second: a pid, tuple or struct cannot be JSON, and a crash here
  # would be an ArgumentError out of the settings UI rather than an error it can show.
  @spec store_value(term(), boolean()) ::
          {:ok, String.t()} | {:error, :not_encodable | :secret_key_base_missing}
  defp store_value(value, secret?) do
    case Jason.encode(value) do
      {:ok, json} when secret? ->
        case encrypt(json) do
          {:ok, encrypted} -> {:ok, encrypted}
          {:error, :secret_key_base_missing} = err -> err
        end

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

    insert_setting(changeset,
      on_conflict: [set: [value: stored, secret: secret?, updated_at: now]],
      conflict_target: [:user_id, :key]
    )
  end

  # SQLite reports a foreign-key violation with a nil constraint name, so
  # `foreign_key_constraint/3` cannot map it; translate the raise instead.
  defp insert_setting(changeset, opts) do
    Repo.insert(changeset, opts)
  rescue
    error in Ecto.ConstraintError ->
      Logger.warning("setting #{changeset.data.key} cannot be stored: #{error.type} failed")
      {:error, Ecto.Changeset.add_error(changeset, :user_id, "does not exist")}
  end

  @doc """
  Reads every setting of a user as `%{"key" => decoded value}`.

  Secret values come back as `:redacted`: a bulk read must never spread
  plaintext, and the settings UI needs readiness (the key exists), not the
  value — `get/3` is the deliberate path to a secret.
  """
  @spec all(integer()) :: %{optional(String.t()) => term()}
  def all(user_id) do
    user_id
    |> by_user()
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
  never capable, and the other providers each need their key or URL.
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

  defp provider_configured?(user_id, "libretranslate"),
    do: credential?(user_id, "libretranslate_url")

  defp provider_configured?(user_id, "llm"), do: credential?(user_id, "OPENAI_API_KEY")
  defp provider_configured?(_user_id, _unknown), do: false

  # A row that exists and holds JSON `null` must not be confused with an absent row:
  # `get/3` returns nil for both, and treating "cleared key" as "no key" would fall
  # through to the environment and re-enable a capability the user just switched off.
  @missing :__missing_setting__

  # The settings row wins and environment variables are the fallback. Environment
  # names are the uppercase form of the setting key (`OPENAI_API_KEY`,
  # `DEEPL_API_KEY`, `LIBRETRANSLATE_URL`). An explicitly empty stored key stays
  # empty rather than falling through, so it still disables the capability.
  defp credential?(user_id, key) do
    case impl().get(user_id, key, @missing) do
      @missing -> present?(System.get_env(String.upcase(key)))
      value -> present?(value)
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  # ── storage ─────────────────────────────────────────────────────────────────

  @spec by_user(integer()) :: Ecto.Query.t()
  defp by_user(user_id) do
    from(s in Setting, where: s.user_id == ^user_id)
  end

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
    do_decrypt(cipher, key, fallback)
  rescue
    error in ArgumentError ->
      Logger.warning("setting #{key} cannot be decrypted (#{Exception.message(error)})")
      fallback
  end

  defp do_decrypt(cipher, key, fallback) do
    crypto_key = derived_key()

    case Plug.Crypto.MessageEncryptor.decrypt(cipher, crypto_key, crypto_key) do
      {:ok, plain} ->
        decode(plain, key, fallback)

      :error ->
        Logger.warning("setting #{key} failed authentication; returning default")
        fallback
    end
  end

  # Deterministic derivation: the same SECRET_KEY_BASE yields the same
  # 32-byte key on every boot, so no key column is needed. A missing
  # SECRET_KEY_BASE raises here rather than storing plaintext.
  defp derived_key do
    Plug.Crypto.KeyGenerator.generate(secret_key_base(), @secret_salt,
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
