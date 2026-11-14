defmodule Ashiato.HTTPTest do
  use ExUnit.Case, async: true

  alias Ashiato.HTTP

  @base_url "https://service.test"

  test "a 200 JSON reply comes back decoded, with the :json body forwarded" do
    plug = fn conn ->
      assert conn.method == "POST"
      assert conn.body_params == %{"text" => "橋"}
      Req.Test.json(conn, %{"tokens" => []})
    end

    assert HTTP.post(@base_url, json: %{text: "橋"}, plug: plug) == {:ok, %{"tokens" => []}}
  end

  test "a 200 text reply comes back as a binary" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "1.2.3") end

    assert HTTP.get(@base_url, plug: plug) == {:ok, "1.2.3"}
  end

  test "a non-200 reply returns only the status, never the body" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 503, "SECRET-PAGE-BODY") end

    result = HTTP.get(@base_url, plug: plug)
    assert result == {:error, {:http, 503}}
    refute inspect(result) =~ "SECRET-PAGE-BODY"
  end

  test "a malformed URL, a missing scheme, another scheme, an empty host, and a non-binary URL are rejected without calling Req" do
    counter = :counters.new(1, [:atomics])

    plug = fn conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, 200, "called")
    end

    for url <- ["not a url", "lt.example.com", "ftp://example.com", "https://"] do
      assert HTTP.get(url, plug: plug) == {:error, :invalid_url}
    end

    assert HTTP.get(42, plug: plug) == {:error, :invalid_url}
    assert :counters.get(counter, 1) == 0
  end

  test "a non-keyword opts list returns :invalid_options" do
    assert HTTP.get(@base_url, :not_opts) == {:error, :invalid_options}
    assert HTTP.get(@base_url, ["not", "keyword"]) == {:error, :invalid_options}
  end

  test "a transport failure keeps its atom reason" do
    plug = fn conn -> Req.Test.transport_error(conn, :timeout) end

    assert HTTP.get(@base_url, plug: plug) == {:error, {:transport, :timeout}}
  end

  test "a binary-carrying failure reason is reduced to :unknown" do
    transport_plug = fn conn ->
      put_in(conn.private[:req_test_exception], %Req.TransportError{
        reason: "server closed mid-handshake"
      })
    end

    protocol_plug = fn conn ->
      put_in(conn.private[:req_test_exception], %Req.HTTPError{
        protocol: :http2,
        reason: "debug data"
      })
    end

    assert HTTP.get(@base_url, plug: transport_plug) == {:error, {:transport, :unknown}}
    assert HTTP.get(@base_url, plug: protocol_plug) == {:error, {:transport, :unknown}}
  end

  test "an HTTP protocol failure maps to a transport atom" do
    plug = fn conn ->
      put_in(conn.private[:req_test_exception], %Req.HTTPError{
        protocol: :http1,
        reason: :protocol_error
      })
    end

    assert HTTP.get(@base_url, plug: plug) == {:error, {:transport, :protocol_error}}
  end

  test "a raised HTTP protocol failure maps to a transport atom" do
    plug = fn _conn -> raise %Req.HTTPError{protocol: :http1, reason: :protocol_error} end

    assert HTTP.get(@base_url, plug: plug) == {:error, {:transport, :protocol_error}}
  end

  test "a malformed JSON reply returns :invalid_json and never the body" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{\"secret\": \"page text\"")
    end

    result = HTTP.get(@base_url, plug: plug)
    assert result == {:error, :invalid_json}
    refute inspect(result) =~ "page text"
  end

  test "a non-200 JSON reply maps to its status even when the body is malformed JSON" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, "{\"broken\": ")
    end

    result = HTTP.get(@base_url, plug: plug)
    assert result == {:error, {:http, 500}}
    refute result == {:error, :invalid_json}
  end

  test "a 302 is not followed and the plug runs once" do
    counter = :counters.new(1, [:atomics])

    plug = fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_resp_header("location", "https://other.test/next")
      |> Plug.Conn.send_resp(302, "")
    end

    assert HTTP.get(@base_url, plug: plug) == {:error, {:http, 302}}
    assert :counters.get(counter, 1) == 1
  end

  test "a 500 is not retried and the plug runs once" do
    counter = :counters.new(1, [:atomics])

    plug = fn conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, 500, "boom")
    end

    assert HTTP.get(@base_url, plug: plug) == {:error, {:http, 500}}
    assert :counters.get(counter, 1) == 1
  end

  test "options outside the allow-list are dropped and allowed ones are forwarded" do
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "x-probe") == ["1"]
      assert conn.query_params == %{"q" => "1"}
      Plug.Conn.send_resp(conn, 200, "ok")
    end

    assert HTTP.get(@base_url,
             plug: plug,
             headers: [{"x-probe", "1"}],
             params: [q: "1"],
             bogus: :dropped
           ) == {:ok, "ok"}
  end

  test "Application/JSON with mixed case and a JSON body decodes" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "Application/JSON")
      |> Plug.Conn.send_resp(200, "{\"key\":\"val\"}")
    end

    assert HTTP.get(@base_url, plug: plug) == {:ok, %{"key" => "val"}}
  end

  test "text/plain with parameters containing json returns the raw binary" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8; json=false")
      |> Plug.Conn.send_resp(200, "plain text body")
    end

    assert HTTP.get(@base_url, plug: plug) == {:ok, "plain text body"}
  end

  test "application/problem+json with a JSON body decodes" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/problem+json")
      |> Plug.Conn.send_resp(200, "{\"type\":\"about:blank\"}")
    end

    assert HTTP.get(@base_url, plug: plug) == {:ok, %{"type" => "about:blank"}}
  end
end
