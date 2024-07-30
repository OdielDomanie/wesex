defmodule Wesex.Websocket.Opening do
  @moduledoc false
  # The client is in the process of connecting and opening.

  alias Wesex.Websocket.{Closed, Open}
  alias __MODULE__, as: Opening
  alias Mint.{HTTP, Types}

  @type data_frame :: {:text, String.t()} | {:binary, binary()}

  @type t :: %__MODULE__{
          status_resp: {:status, Types.request_ref(), non_neg_integer()} | nil,
          headers_resp: {:headers, Types.request_ref(), Types.headers()} | nil,
          done_resp: {:done, Types.request_ref()} | nil,
          con: HTTP.t(),
          ws_ref: reference(),
          ws_opts: keyword(),
          timer: reference()
        }

  @enforce_keys [:con, :ws_ref, :timer]
  defstruct [
    :con,
    :ws_ref,
    :status_resp,
    :headers_resp,
    :done_resp,
    :timer,
    ws_opts: []
  ]

  @doc false
  def ok_fun, do: :ok
  @doc false
  def ok_fun(_), do: :ok

  def default_timeout, do: 5_000

  @doc """
  Closes the `Mint.HTTP` connection.
  """
  def fail(%Opening{con: con, timer: timer, ws_ref: ref}) do
    _con = HTTP.close(con)
    cancel_flush_timer(timer, ref)

    Closed.new()
  end

  defp cancel_flush_timer(timer, ref) do
    _ = Process.cancel_timer(timer)

    _ =
      receive do
        {:open_timeout, ^ref} -> nil
      after
        0 -> nil
      end

    :ok
  end

  @spec finish_opening(t, [...]) :: {:ok, Open.t(), [...]} | {:error, Closed.t(), reason :: any}
  def finish_opening(
        %Opening{
          con: con,
          ws_ref: ws_ref,
          status_resp: {:status, ws_ref, status},
          headers_resp: {:headers, ws_ref, headers},
          ws_opts: ws_opts
        } = state,
        rest_resps
      ) do
    Mint.WebSocket.new(con, ws_ref, status, headers, ws_opts)
    |> case do
      {:ok, con, ws} ->
        :ok = cancel_flush_timer(state.timer, ws_ref)

        state = %Open{
          con: con,
          ponged: true,
          ping_timer: Process.send_after(self(), {:ping_time, ws_ref}, 0),
          ping_intv: Open.default_ping_intv(),
          ws: ws,
          ws_ref: ws_ref
        }

        {:ok, state, rest_resps}

      {:error, con, reason} ->
        state = %{state | con: con}
        state = fail(state)
        {:error, state, reason}
    end
  end
end
