defmodule Wesex do
  alias Wesex.MintAdapter
  alias __MODULE__.Connection

  defmacro __using__(arg) do
    quote do
      alias Wesex.Connection

      use GenServer, unquote(arg)

      @impl GenServer
      def init(opts) do
        cb_state = Keyword.fetch!(opts, :cb_state)
        callbacks = Keyword.fetch!(opts, :callbacks)
        adapter = opts[:adapter] || MintAdapter
        url = Keyword.fetch!(opts, :url)
        headers = opts[:headers] || []
        adapter_opts = opts[:adapter_opts] || []

        case Connection.connect(adapter, {callbacks, cb_state}, url, headers, adapter_opts) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, reason} ->
            {:stop, reason}
        end
      end

      @impl GenServer
      def handle_info(msg, conn) do
        case Connection.event(conn, msg) do
          %Connection{} = conn ->
            if Connection.short_status(conn) == :closed do
              {:stop, :normal, conn}
            else
              {:noreply, conn}
            end

          false ->
            {:noreply, conn, {:continue, :handle_info}}
        end
      end

      defoverridable init: 1
    end
  end
end
