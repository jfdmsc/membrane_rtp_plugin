defmodule Membrane.RTP.JitterBuffer do
  @doc """
  Element that buffers and reorders RTP packets based on sequence_number.
  """
  use Membrane.Filter
  use Membrane.Log
  use Bunch

  alias Membrane.{Buffer, RTP}
  alias __MODULE__.{BufferStore, Record}

  @type packet_index :: non_neg_integer()

  def_output_pad :output,
    caps: RTP

  def_input_pad :input,
    caps: RTP,
    demand_unit: :buffers

  @default_latency 200 |> Membrane.Time.milliseconds()

  @max_s24_val 8_388_607
  @min_s24_val -8_388_608

  def_options clock_rate: [type: :integer, spec: RTP.clock_rate_t()],
              latency: [
                type: :time,
                default: @default_latency,
                description: """
                Delay introduced by JitterBuffer
                """
              ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    defstruct store: %BufferStore{},
              clock_rate: nil,
              latency: nil,
              waiting?: true,
              max_latency_timer: nil,
              stats: %{expected_prior: 0, received_prior: 0, last_transit: nil, jitter: 0.0}

    @type t :: %__MODULE__{
            store: BufferStore.t(),
            clock_rate: RTP.clock_rate_t(),
            latency: Membrane.Time.t(),
            waiting?: boolean(),
            max_latency_timer: reference,
            stats: %{
              expected_prior: non_neg_integer(),
              received_prior: non_neg_integer(),
              last_transit: non_neg_integer() | nil,
              jitter: float()
            }
          }
  end

  defmodule Stats do
    @moduledoc """
    JitterBuffer stats that can be used for Receiver report generation
    """

    @enforce_keys [:fraction_lost, :total_lost, :highest_seq_num, :interarrival_jitter]

    defstruct @enforce_keys

    @type t :: %__MODULE__{
            fraction_lost: float(),
            total_lost: non_neg_integer(),
            highest_seq_num: Membrane.RTP.JitterBuffer.packet_index(),
            interarrival_jitter: non_neg_integer()
          }
  end

  @impl true
  def handle_init(%__MODULE__{latency: latency, clock_rate: clock_rate}) do
    if latency == nil do
      raise "Latancy cannot be nil"
    end

    {:ok, %State{latency: latency, clock_rate: clock_rate}}
  end

  @impl true
  def handle_start_of_stream(:input, _context, state) do
    Process.send_after(
      self(),
      :initial_latency_passed,
      state.latency |> Membrane.Time.to_milliseconds()
    )

    {:ok, %{state | waiting?: true}}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state),
    do: {{:ok, demand: {:input, size}}, state}

  @impl true
  def handle_end_of_stream(:input, _context, %State{store: store} = state) do
    {stats, state} = get_and_update_stats(state)
    IO.inspect(stats)

    store
    |> BufferStore.dump()
    |> Enum.map(&record_to_action/1)
    ~> {{:ok, &1 ++ [end_of_stream: :output]}, %State{state | store: %BufferStore{}}}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{store: store, waiting?: true} = state) do
    state = update_jitter(buffer, state)

    state =
      case BufferStore.insert_buffer(store, buffer) do
        {:ok, result} ->
          %State{state | store: result}

        {:error, :late_packet} ->
          warn("Late packet has arrived")
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_process(:input, buffer, _context, %State{store: store} = state) do
    state = update_jitter(buffer, state)

    case BufferStore.insert_buffer(store, buffer) do
      {:ok, result} ->
        state = %State{state | store: result}
        send_buffers(state)

      {:error, :late_packet} ->
        warn("Late packet has arrived")
        {{:ok, redemand: :output}, state}
    end
  end

  @impl true
  def handle_other(:initial_latency_passed, _context, state) do
    state = %State{state | waiting?: false}
    send_buffers(state)
  end

  @impl true
  def handle_other(:send_buffers, _context, state) do
    state = %State{state | max_latency_timer: nil}
    send_buffers(state)
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    {stats, state} = get_and_update_stats(state)
    {{:ok, notify: {:jitter_buffer_stats, stats}}, state}
  end

  defp send_buffers(%State{store: store} = state) do
    # Shift buffers that stayed in queue longer than latency and any gaps before them
    {too_old_records, store} = BufferStore.shift_older_than(store, state.latency)
    # Additionally, shift buffers as long as there are no gaps
    {buffers, store} = BufferStore.shift_ordered(store)

    actions = (too_old_records ++ buffers) |> Enum.map(&record_to_action/1)

    state = %{state | store: store} |> set_timer()

    {{:ok, actions ++ [redemand: :output]}, state}
  end

  @spec set_timer(State.t()) :: State.t()
  defp set_timer(%State{max_latency_timer: nil, latency: latency} = state) do
    new_timer =
      case BufferStore.first_record_timestamp(state.store) do
        nil ->
          nil

        buffer_ts ->
          since_insertion = Membrane.Time.monotonic_time() - buffer_ts
          send_after_time = max(0, latency - since_insertion) |> Membrane.Time.to_milliseconds()
          Process.send_after(self(), :send_buffers, send_after_time)
      end

    %State{state | max_latency_timer: new_timer}
  end

  defp set_timer(%State{max_latency_timer: timer} = state) when timer != nil, do: state

  defp record_to_action(nil), do: {:event, {:output, %Membrane.Event.Discontinuity{}}}
  defp record_to_action(%Record{buffer: buffer}), do: {:buffer, {:output, buffer}}

  @spec get_and_update_stats(State.t()) :: {Stats.t(), State.t()}
  def get_and_update_stats(%State{
        store: store,
        stats:
          %{expected_prior: expected_prior, received_prior: received_prior, jitter: jitter} =
            state
      }) do
    use Bitwise

    # Variable names follow algorithm A.3 from RFC3550 (https://tools.ietf.org/html/rfc3550#appendix-A.3)
    %{base_index: base_seq, end_index: extended_max, received: received} = store
    expected = extended_max - base_seq + 1
    lost = expected - received

    capped_lost =
      cond do
        lost > @max_s24_val -> @max_s24_val
        lost < @min_s24_val -> @min_s24_val
        true -> lost
      end

    expected_interval = expected - expected_prior
    received_interval = received - received_prior
    lost_interval = expected_interval - received_interval

    fraction =
      if expected_interval == 0 || lost_interval <= 0 do
        0.0
      else
        lost_interval / expected_interval
      end

    stored_stats = %{expected_prior: expected, received_prior: received, jitter: jitter}

    {%Stats{
       fraction_lost: fraction,
       total_lost: capped_lost,
       highest_seq_num: extended_max,
       interarrival_jitter: jitter
     }, %State{state | stats: stored_stats}}
  end

  defp update_jitter(
         %Buffer{metadata: %{rtp: %{timestamp: buffer_ts}} = metadata},
         %State{clock_rate: clock_rate, stats: %{jitter: jitter, last_transit: last_transit}} =
           state
       ) do
    alias Membrane.Time
    # Algorithm from https://tools.ietf.org/html/rfc3550#appendix-A.8
    arrival_ts = Map.get(metadata, :arrival_ts, Time.vm_time())

    # Algorithm from https://tools.ietf.org/html/rfc3550#appendix-A.8
    arrival = arrival_ts |> Time.as_seconds() |> Ratio.mult(clock_rate) |> Ratio.trunc()
    transit = arrival - buffer_ts

    if last_transit == nil do
      put_in(state.stats.last_transit, transit)
    else
      d = abs(transit - last_transit)
      new_jitter = jitter + 1 / 16 * (d - jitter)

      state
      |> put_in([:stats, :jitter], new_jitter)
      |> put_in([:stats, :last_transit], transit)
    end
  end
end
