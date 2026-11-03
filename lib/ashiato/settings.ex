defmodule Ashiato.Settings do
  @moduledoc """
  The typed accessor over the per-user `settings` key-value table (D47), and
  the only module that knows settings are key-value — everything else calls
  this context and works with typed values.

  Values are JSON-encoded in the `value` column, so a boolean reads back as a
  boolean and a list as a list. Rows marked `secret: true` are encrypted at
  rest with a key derived deterministically from `SECRET_KEY_BASE`, and the
  plaintext of a secret never reaches a log or an error report.

  The module is also the behaviour of the settings boundary: `impl/0` returns
  the configured implementation (defaulting to this one), so later waves call
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
              {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  @callback all(integer()) :: %{optional(String.t()) => term()}

  # §8 defaults: a missing row must never force a caller to special-case nil
  # for the settings the requirements name.
  @defaults %{
    "ai_features_enabled" => false,
    "translation_enabled" => false,
    "translation_provider" => "google_free",
    "min_encounters" => 2,
    "new_cards_per_day" => 10,
    "maturity_threshold_days" => 21
  }

  @secret_salt "ashiato settings"

  @doc """
  Returns the configured implementation of the `get/3`, `put/4` and `all/1`
  callbacks from application config (`config :ashiato, :settings, MyImpl`),
  defaulting to this module — the repo-backed accessor. Later waves call
  `impl().get/3` and never name a concrete module.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:ashiato, :settings, __MODULE__)

  @doc """
  Reads one setting as a decoded value. A missing row falls back to the §8
  requirement defaults for the settings named there, and to `default` for any
  other key.

  A secret row is decrypted first; if authentication fails the default is
  returned and the failure is logged without the value.
  """
  @spec get(integer(), String.t(), term()) :: term()
  def get(user_id, key, default \\ nil) do
    fallback = Map.get(@defaults, key, default)

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
          {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(user_id, key, value, opts \\ []) do
    secret? = Keyword.get(opts, :secret, false)
    stored = if secret?, do: encrypt(value), else: Jason.encode!(value)
    now = Utils.utc_now()

    %Setting{user_id: user_id, key: key}
    |> Ecto.Changeset.change(value: stored, secret: secret?)
    |> Repo.insert(
      on_conflict: [set: [value: stored, secret: secret?, updated_at: now]],
      conflict_target: [:user_id, :key]
    )
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
  The AI gate (D43): `ai_features_enabled` is on AND a non-empty
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
  The translation gate (§7.5): `translation_enabled` is on AND the selected
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

  # The settings row wins and environment variables are the fallback for the
  # same values (§7.5); an explicitly empty key stays empty rather than
  # falling through to the environment, so it still disables (D43).
  defp credential?(user_id, key) do
    case impl().get(user_id, key, nil) do
      nil -> present?(System.get_env(key))
      value -> present?(value)
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  # ── storage ─────────────────────────────────────────────────────────────────

  @spec by_user(integer()) :: Ecto.Query.t()
  defp by_user(user_id) do
    from(s in Setting, where: s.user_id == ^user_id)
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

  defp encrypt(value) do
    key = derived_key()
    Jason.encode!(value) |> Plug.Crypto.MessageEncryptor.encrypt(key, key)
  end

  defp decrypt(cipher, key, fallback) do
    crypto_key = derived_key()

    case Plug.Crypto.MessageEncryptor.decrypt(cipher, crypto_key, crypto_key) do
      {:ok, plain} ->
        decode(plain, key, fallback)

      :error ->
        Logger.warning("setting #{key} failed authentication; returning default")
        fallback
    end
  end

  # Deterministic derivation (D47): the same SECRET_KEY_BASE yields the same
  # 32-byte key on every boot, so no key column is needed. A missing
  # SECRET_KEY_BASE raises here rather than storing plaintext.
  defp derived_key do
    Plug.Crypto.KeyGenerator.generate(secret_key_base(), @secret_salt,
      iterations: 1000,
      length: 32
    )
  end

  defp secret_key_base do
    Application.get_env(:ashiato, AshiatoWeb.Endpoint)[:secret_key_base]
  end
end
