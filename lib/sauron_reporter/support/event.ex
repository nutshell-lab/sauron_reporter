defmodule SauronReporter.Support.Event do
  @moduledoc """
  An event Sauron pushed on the app's support channel, as the client
  broadcasts it on the app's PubSub: `{SauronReporter.Support, %Event{}}`.

    * `event` — Sauron's name: `"message"`, `"typing"`, `"modules"`,
      `"submitted"`, `"claimed"`, `"rejected"`, `"closed"`,
      `"converted"`, `"screenshot_asked"`, `"callback_requested"`,
      `"called"`;
    * `conversation_id`, `user_id` — whose it is (the app's user id, as
      the app gave it to `SauronReporter.Support.open/4`);
    * `payload` — Sauron's map as it came (string keys): `message`,
      `operator`, `typing`, `modules`, `request`, `reason`, `by`… A
      system message's content carries, beside its `code` and `text`,
      the facts to word it (Sauron's step 3): `operator` `{id, name}`
      (the first name), `phone`, `email`, `reason`, each where it
      applies; a user's message its `ref`. See Sauron's
      `SauronWeb.SupportChannel`.
  """

  @type t :: %__MODULE__{
          event: String.t(),
          conversation_id: String.t() | nil,
          user_id: String.t() | nil,
          payload: map()
        }

  defstruct [:event, :conversation_id, :user_id, payload: %{}]
end
