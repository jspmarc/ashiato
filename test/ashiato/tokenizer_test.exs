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

  test "the measured behaviours survive the mapping: kana kept, inflection normalised, homophones distinct" do
    stub_reply(fn conn ->
      Req.Test.json(conn, %{
        "tokens" => [
          %{"surface" => "はし", "lemma" => "はし", "reading" => "ハシ", "part_of_speech" => "名詞"},
          %{"surface" => "橋", "lemma" => "橋", "reading" => "ハシ", "part_of_speech" => "名詞"},
          %{"surface" => "箸", "lemma" => "箸", "reading" => "ハシ", "part_of_speech" => "名詞"},
          %{"surface" => "食べた", "lemma" => "食べる", "reading" => "タベタ", "part_of_speech" => "動詞"}
        ]
      })
    end)

    assert {:ok, tokens} = Tokenizer.tokenize("はし 橋 箸 食べた")

    # kana is never converted to kanji: the lemma keeps the orthography on screen
    assert Enum.at(tokens, 0).lemma == "はし"
    # a shared reading is not an identity: three lemmas stay three tokens
    assert tokens |> Enum.take(3) |> Enum.map(& &1.lemma) |> Enum.uniq() |> length() == 3
    # the reading is part of identity, so it is normalised for all three (same ハシ)
    assert tokens |> Enum.take(3) |> Enum.map(& &1.reading) |> Enum.uniq() == ["はし"]
    # inflection is normalised to the dictionary form
    assert Enum.at(tokens, 3).lemma == "食べる"
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

    assert {:error, {:malformed_reply, {:map, ["nope"]}}} = Tokenizer.Http.tokenize("食べた")
  end

  test "a malformed token names the entry instead of raising" do
    stub_reply(fn conn -> Req.Test.json(conn, %{"tokens" => [%{"surface" => "食べ"}]}) end)

    # the error names the position, not the page text: this term ends up in a log
    assert Tokenizer.Http.tokenize("食べた") == {:error, {:malformed_token, 0}}
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
