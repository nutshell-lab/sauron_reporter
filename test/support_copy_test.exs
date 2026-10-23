defmodule SauronReporter.SupportCopyTest do
  use ExUnit.Case, async: true

  alias SauronReporter.Support.Copy

  @ctx %{team: "l'équipe m2", title: "Assistance", email: "camille@ville.fr", request: nil}

  defp line(code, facts \\ %{}, ctx \\ @ctx) do
    content =
      Map.merge(%{"type" => "event", "code" => code, "text" => "Le texte de Sauron."}, facts)

    Copy.system(content, ctx)
  end

  @thomas %{"operator" => %{"id" => "op-1", "name" => "Thomas"}}

  test "each code worded from its facts, in the app's voice" do
    assert line("claimed", @thomas) ==
             {:event, "Thomas, de l'équipe m2, a rejoint la conversation"}

    assert line("screenshot_asked", @thomas) ==
             {:event, "Thomas vous demande une capture d'écran"}

    assert line("called", Map.put(@thomas, "phone", "06 39 98 42 17")) ==
             {:event, "Thomas vous a appelé au 06 39 98 42 17"}

    assert line("resolved", @thomas) == {:event, "Thomas a clos cette demande"}

    assert line("callback_requested", %{"phone" => "06 39 98 42 17"}) ==
             {:event, "Rappel demandé au 06 39 98 42 17"}

    assert line("submitted", %{"email" => "c.roussel@ville.fr"}) ==
             {:line,
              "C'est envoyé à l'équipe m2 : nous vous répondrons ici, ou par e-mail à c.roussel@ville.fr."}

    assert {:paragraphs, [first, _]} = line("no_operator", %{"email" => "c.roussel@ville.fr"})
    assert first =~ "par e-mail à c.roussel@ville.fr."

    assert line("rejected", %{"reason" => "Hors du périmètre."}) ==
             {:line, "L'équipe m2 n'a pas retenu votre demande : Hors du périmètre."}

    assert line("closed_by_user") == {:event, "Vous avez clos cette demande"}
  end

  test "without the facts: the request's, else the team" do
    request = %{"claimed_by" => %{"name" => "Thomas Martin"}, "callback_phone" => "0601"}
    ctx = %{@ctx | request: request}

    assert line("claimed", %{}, ctx) ==
             {:event, "Thomas, de l'équipe m2, a rejoint la conversation"}

    assert line("called", %{}, ctx) == {:event, "Thomas vous a appelé au 0601"}
    assert line("called") == {:event, "L'équipe m2 vous a appelé"}
    assert line("resolved") == {:event, "L'équipe m2 a clos cette demande"}
    assert line("screenshot_asked") == {:event, "L'équipe m2 vous demande une capture d'écran"}
    assert line("claimed") == {:event, "Quelqu'un de l'équipe m2 a rejoint la conversation"}
    assert line("rejected") == {:line, "L'équipe m2 n'a pas retenu votre demande."}
    assert line("callback_requested") == {:event, "Rappel demandé"}

    assert line("submitted", %{}, %{@ctx | email: nil}) ==
             {:line, "C'est envoyé à l'équipe m2 : nous vous répondrons ici, ou par e-mail."}
  end

  test "Sauron's text only for a code the panel does not know" do
    for code <- ~w(claimed screenshot_asked called resolved rejected submitted closed_by_user) do
      {_, words} = line(code, @thomas)
      refute words =~ "Le texte de Sauron", code
    end

    assert line("inconnu") == {:line, "Le texte de Sauron."}
  end

  test "a person answers, in the team's name; what a file is, before its size" do
    assert Copy.person("l'équipe m2") ==
             "Une personne de l'équipe m2 vous répond — ce n'est pas un assistant automatique."

    assert Copy.file_kind(%{"content_type" => "application/pdf"}) == "PDF, "
    assert Copy.file_kind(%{"content_type" => "image/png"}) == "image, "
    assert Copy.file_kind(%{"type" => "image"}) == "image, "
    assert Copy.file_kind(%{"type" => "file", "name" => "Devis.PDF"}) == "PDF, "
    assert Copy.file_kind(%{"type" => "file", "name" => "notes.txt"}) == ""
    assert Copy.file_kind(nil) == ""
  end
end
