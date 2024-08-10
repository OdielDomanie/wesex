defmodule Wesex.Websocket.Opening do
  @moduledoc false
  # The client is in the process of connecting and opening.

  alias Wesex.Websocket.{Closed, Open}
  alias __MODULE__, as: Opening
  alias Wesex.Adapter

  @type data_frame :: {:text, String.t()} | {:binary, binary()}

  @type t :: %__MODULE__{
          status_resp: {:status, reference(), non_neg_integer()} | nil,
          headers_resp: {:headers, reference(), Adapter.headers()} | nil,
          done_resp: {:done, reference()} | nil,
          con: Adapter.con(),
          ws_ref: reference(),
          ws_opts: keyword(),
          timer: reference(),
          adapter: Adapter.impl()
        }

  @enforce_keys [:con, :ws_ref, :timer, :adapter]
  defstruct [
    :con,
    :ws_ref,
    :status_resp,
    :headers_resp,
    :done_resp,
    :timer,
    :adapter,
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
  def fail(%Opening{con: con, timer: timer, ws_ref: ref, adapter: adapter}) do
    _con = adapter.close(con)
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
    state.adapter.new(con, ws_ref, status, headers, ws_opts)
    |> case do
      {:ok, con, ws} ->
        :ok = cancel_flush_timer(state.timer, ws_ref)

        state = %Open{
          con: con,
          ponged: true,
          ping_timer: Process.send_after(self(), {:ping_time, ws_ref}, 0),
          ping_intv: Open.default_ping_intv(),
          ws: ws,
          ws_ref: ws_ref,
          adapter: state.adapter
        }

        {:ok, state, rest_resps}

      {:error, con, reason} ->
        state = %{state | con: con}
        state = fail(state)
        {:error, state, reason}
    end
  end
end
