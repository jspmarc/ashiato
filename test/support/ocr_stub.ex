defmodule Ashiato.OcrStub do
  @moduledoc """
  Stub Unix-socket server standing in for the `ashiato-ocr` service.

  The listener is created synchronously in `start_link/1`, so the socket file
  exists once it returns. Each connection is read as one `packet: 4` frame and
  answered according to the `:handler` result:

    * a map — sent as one framed JSON object
    * `{:raw, binary}` — sent verbatim, to script an unparseable reply
    * `:no_reply` — the connection is held open, simulating a dead service
  """

  @doc "Starts a stub listening on the Unix socket at `:path`."
  @spec start_link(path: String.t(), handler: (map() -> map() | {:raw, binary()} | :no_reply)) ::
          {:ok, pid()}
  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    handler = Keyword.fetch!(opts, :handler)
    File.rm(path)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {:local, path}])
    Task.start_link(fn -> accept_loop(listener, handler) end)
  end

  @doc """
  Child spec with a unique id, so several stubs can be supervised in one test and each
  is torn down independently.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  defp accept_loop(listener, handler) do
    {:ok, sock} = :gen_tcp.accept(listener)
    serve(sock, handler)
    :gen_tcp.close(sock)
    accept_loop(listener, handler)
  end

  defp serve(sock, handler) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, data} -> respond(sock, handler.(Jason.decode!(data)))
      {:error, _} -> :ok
    end
  end

  defp respond(sock, {:raw, payload}), do: :gen_tcp.send(sock, payload)
  defp respond(sock, :no_reply), do: hold_open(sock)
  defp respond(sock, reply), do: :gen_tcp.send(sock, Jason.encode!(reply))

  defp hold_open(sock) do
    case :gen_tcp.recv(sock, 0, 60_000) do
      {:ok, _data} -> hold_open(sock)
      {:error, _} -> :ok
    end
  end
end
