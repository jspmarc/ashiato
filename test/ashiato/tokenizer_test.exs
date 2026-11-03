defmodule Ashiato.TokenizerTest do
  # The fake registers a named Agent and the HTTP test writes application env;
  # both are VM-global, so these tests must not run concurrently.
  use ExUnit.Case, async: false

  alias Ashiato.Tokenizer
  alias Ashiato.Tokenizer.Fake

  test "a katakana reading comes back as hiragana, ー untouched" do
    assert Tokenizer.Http.to_hiragana("キャッチャー") == "きゃっちゃー"
    assert Tokenizer.Http.to_hiragana("ケーキ") == "けーき"
  end

  test "HTTP impl maps the service's JSON shape onto token maps" do
    Application.put_env(
      :ashiato,
      Tokenizer,
      base_url: "https://jp-dict.test",
      plug: {Req.Test, Tokenizer.Http}
    )

    on_exit(fn -> Application.delete_env(:ashiato, Tokenizer) end)

    Req.Test.stub(Tokenizer.Http, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/tokenize"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"text" => "食べた"}

      Req.Test.json(conn, %{
        "tokens" => [
          %{"surface" => "食べ", "lemma" => "食べる", "reading" => "タベ", "part_of_speech" => "動詞"},
          %{"surface" => "たべる", "lemma" => "たべる", "reading" => "タベル", "part_of_speech" => "動詞"}
        ]
      })
    end)

    assert Tokenizer.tokenize("食べた") ==
             {:ok,
              [
                %{surface: "食べ", lemma: "食べる", reading: "たべ", part_of_speech: "動詞"},
                %{surface: "たべる", lemma: "たべる", reading: "たべる", part_of_speech: "動詞"}
              ]}
  end

  test "kana is not converted to kanji, through the fake" do
    start_supervised!({Fake, tokens: [token("たべる", "たべる", "タベル")]})

    assert {:ok, [token]} = Fake.tokenize("たべる")
    assert token.surface == "たべる"
    assert token.lemma == "たべる"
    assert Fake.calls() == ["たべる"]
  end

  test "inflection is normalised to the dictionary form, through the fake" do
    start_supervised!({Fake, tokens: [token("食べ", "食べる", "タベ", "動詞")]})

    assert {:ok, [token]} = Fake.tokenize("食べた")
    assert token.lemma == "食べる"
  end

  test "homophones stay three distinct tokens, through the fake" do
    tokens = [token("はし", "はし", "ハシ"), token("橋", "橋", "ハシ"), token("箸", "箸", "ハシ")]
    start_supervised!({Fake, tokens: tokens})

    assert {:ok, ^tokens} = Fake.tokenize("はし 橋 箸")
  end

  test "impl/0 routes through the configured implementation" do
    start_supervised!({Fake, tokens: [token("橋", "橋", "ハシ")]})
    Application.put_env(:ashiato, Tokenizer, impl: Fake)
    on_exit(fn -> Application.delete_env(:ashiato, Tokenizer) end)

    # the exact hook wave 3 configures: behaviour in, concrete module out
    assert Tokenizer.tokenize("橋") == {:ok, [token("橋", "橋", "ハシ")]}
    assert Fake.calls() == ["橋"]
  end

  test "a non-200 reply is an error tuple, not a crash" do
    stub_reply(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert Tokenizer.Http.tokenize("食べた") == {:error, {:unexpected_status, 500}}
  end

  test "a 200 reply without a token list is rejected, not read as an empty page" do
    stub_reply(fn conn -> Req.Test.json(conn, %{"nope" => []}) end)

    assert {:error, {:malformed_reply, %{"nope" => []}}} = Tokenizer.Http.tokenize("食べた")
  end

  test "a malformed token names the entry instead of raising" do
    stub_reply(fn conn -> Req.Test.json(conn, %{"tokens" => [%{"surface" => "食べ"}]}) end)

    assert Tokenizer.Http.tokenize("食べた") ==
             {:error, {:malformed_token, %{"surface" => "食べ"}}}
  end

  test "fake returns {:error, reason} when configured" do
    start_supervised!({Fake, error: :service_down})

    assert Fake.tokenize("何か") == {:error, :service_down}
    assert Fake.calls() == ["何か"]
  end

  defp token(surface, lemma, reading, part_of_speech \\ "名詞") do
    %{surface: surface, lemma: lemma, reading: reading, part_of_speech: part_of_speech}
  end

  # Points the HTTP client at a Req.Test stub: no socket, no service.
  defp stub_reply(plug) do
    Application.put_env(:ashiato, Tokenizer,
      base_url: "https://jp-dict.test",
      plug: {Req.Test, Tokenizer.Http}
    )

    on_exit(fn -> Application.delete_env(:ashiato, Tokenizer) end)
    Req.Test.stub(Tokenizer.Http, plug)
  end
end
