defmodule ChallengeGov.Challenges do
  @moduledoc """
  Context for Challenges

  Statuses for challenges:
  - pending: Awaiting review by an admin, hidden to the public
  - created: Published by an admin, viewable to the public
  - archived: Archived by an admin, hidden to the public
  """

  alias ChallengeGov.Accounts
  alias ChallengeGov.Challenges.Challenge
  alias ChallengeGov.Challenges.ChallengeOwner
  alias ChallengeGov.Challenges.FederalPartner
  alias ChallengeGov.Challenges.Logo
  alias ChallengeGov.Challenges.WinnerImage
  alias ChallengeGov.Repo
  alias ChallengeGov.SupportingDocuments
  alias ChallengeGov.Timeline
  alias ChallengeGov.Timeline.Event
  alias ChallengeGov.Emails
  alias ChallengeGov.Mailer
  alias Stein.Filter
  alias Stein.Pagination

  import Ecto.Query

  @behaviour Stein.Filter

  # BOOKMARK: Functions for fetching valid attribute values
  @doc false
  def challenge_types(), do: Challenge.challenge_types()

  @doc false
  def legal_authority(), do: Challenge.legal_authority()

  @doc false
  def sections(), do: Challenge.sections()

  @doc false
  def statuses(), do: Challenge.statuses()

  @doc false
  def status_label(status) do
    status_data = Enum.find(statuses(), fn s -> s.id == status end)

    if status_data do
      status_data.label
    else
      status
    end
  end

  # BOOKMARK: Wizard functionality helpers
  @doc false
  def section_index(section) do
    sections = sections()
    Enum.find_index(sections, fn s -> s.id == section end)
  end

  @doc false
  def next_section(section) do
    sections = sections()

    curr_index = section_index(section)

    if curr_index < length(sections) do
      Enum.at(sections, curr_index + 1)
    end
  end

  @doc false
  def prev_section(section) do
    sections = sections()

    curr_index = section_index(section)

    if curr_index > 0 do
      Enum.at(sections, curr_index - 1)
    end
  end

  @doc false
  def to_section(section, action) do
    case action do
      "next" -> next_section(section)
      "back" -> prev_section(section)
      _ -> nil
    end
  end

  # BOOKMARK: Create and update functions
  @doc """
  New changeset for a challenge
  """
  def new(user) do
    %Challenge{}
    |> challenge_form_preload()
    |> Challenge.create_changeset(%{}, user)
  end

  def create(%{"action" => action, "challenge" => challenge_params}, user) do
    challenge_params =
      challenge_params
      |> check_non_federal_partners

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :challenge,
        changeset_for_action(%Challenge{}, challenge_params, action)
      )
      |> attach_initial_owner(user)
      |> attach_federal_partners(challenge_params)
      |> attach_challenge_owners(challenge_params)
      |> attach_documents(challenge_params)
      |> Ecto.Multi.run(:logo, fn _repo, %{challenge: challenge} ->
        Logo.maybe_upload_logo(challenge, challenge_params)
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{challenge: challenge}} ->
        {:ok, challenge}

      {:error, :challenge, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Changeset for editing a challenge (as an admin)
  """
  def edit(challenge) do
    challenge
    |> challenge_form_preload()
    |> Challenge.update_changeset(%{})
  end

  def update(challenge, %{"action" => action, "challenge" => challenge_params}) do
    challenge_params =
      challenge_params
      |> check_non_federal_partners

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:challenge, changeset_for_action(challenge, challenge_params, action))
      |> attach_federal_partners(challenge_params)
      |> attach_challenge_owners(challenge_params)
      |> attach_documents(challenge_params)
      |> Ecto.Multi.run(:logo, fn _repo, %{challenge: challenge} ->
        Logo.maybe_upload_logo(challenge, challenge_params)
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{challenge: challenge}} ->
        {:ok, challenge}

      {:error, _type, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # BOOKMARK: Create and update helper functions
  defp changeset_for_action(struct, params, action) do
    struct = challenge_form_preload(struct)

    case action do
      a when a == "back" or a == "save_draft" ->
        Challenge.draft_changeset(struct, params)

      _ ->
        Challenge.section_changeset(struct, params)
    end
  end

  defp challenge_form_preload(challenge) do
    Repo.preload(challenge, [
      :federal_partner_agencies,
      :non_federal_partners,
      :events,
      :user,
      :challenge_owner_users
    ])
  end

  defp check_non_federal_partners(params) do
    if Map.get(params, "non_federal_partners") == "" do
      Map.put(params, "non_federal_partners", [])
    else
      params
    end
  end

  # BOOKMARK: Querying functions 
  @doc """
  Get all challenges
  """
  def all(opts \\ []) do
    query =
      Challenge
      |> preload([:agency, :user])
      |> where([c], is_nil(c.deleted_at))
      |> where([c], c.status == "created")
      |> order_by([c], asc: c.end_date, asc: c.id)
      |> Filter.filter(opts[:filter], __MODULE__)

    Pagination.paginate(Repo, query, %{page: opts[:page], per: opts[:per]})
  end

  @doc """
  Get all challenges
  """
  def admin_all(opts \\ []) do
    query =
      Challenge
      |> preload([:agency, :user])
      |> where([c], is_nil(c.deleted_at))
      |> order_by([c], desc: c.status, desc: c.id)
      |> Filter.filter(opts[:filter], __MODULE__)

    Pagination.paginate(Repo, query, %{page: opts[:page], per: opts[:per]})
  end

  @doc """
  Get all challenges for a user
  """
  def all_pending_for_user(user, opts \\ []) do
    start_query =
      if user.role == "challenge_owner" do
        Challenge
        |> where([c], is_nil(c.deleted_at) and c.status == "gsa_review")
        |> join(:inner, [c], co in assoc(c, :challenge_owners))
        |> where([c, co], co.user_id == ^user.id and is_nil(co.revoked_at))
      else
        Challenge
        |> where([c], is_nil(c.deleted_at) and c.status == "gsa_review")
      end

    query =
      start_query
      |> preload([:agency, :user, :challenge_owner_users])
      |> order_on_attribute(opts[:sort])
      |> Filter.filter(opts[:filter], __MODULE__)

    Pagination.paginate(Repo, query, %{page: opts[:page], per: opts[:per]})
  end

  @doc """
  Get all challenges for a user
  """
  def all_for_user(user, opts \\ []) do
    start_query =
      if user.role == "challenge_owner" do
        Challenge
        |> where([c], is_nil(c.deleted_at))
        |> join(:inner, [c], co in assoc(c, :challenge_owners))
        |> where([c, co], co.user_id == ^user.id and is_nil(co.revoked_at))
      else
        Challenge
        |> where([c], is_nil(c.deleted_at))
      end

    query =
      start_query
      |> preload([:agency, :user, :challenge_owner_users])
      |> order_on_attribute(opts[:sort])
      |> Filter.filter(opts[:filter], __MODULE__)

    Pagination.paginate(Repo, query, %{page: opts[:page], per: opts[:per]})
  end

  @doc """
  Get all challenges
  """
  def admin_counts() do
    challenges =
      Challenge
      |> Repo.all()

    pending = Enum.count(challenges, &(&1.status === "pending"))
    created = Enum.count(challenges, &(&1.status === "created"))
    archived = Enum.count(challenges, &(&1.status === "archived"))

    %{pending: pending, created: created, archived: archived}
  end

  @doc """
  Get a challenge
  """
  def get(id) do
    challenge =
      Challenge
      |> where([c], is_nil(c.deleted_at))
      |> where([c], c.id == ^id)
      |> preload([
        :supporting_documents,
        :user,
        :federal_partner_agencies,
        :non_federal_partners,
        :agency,
        :challenge_owner_users
      ])
      |> Repo.one()

    case challenge do
      nil ->
        {:error, :not_found}

      challenge ->
        challenge = Repo.preload(challenge, events: from(e in Event, order_by: e.occurs_on))
        {:ok, challenge}
    end
  end

  @doc """
  Filter a challenge for created state

  Returns `{:error, :not_found}` if the challenge is not created, to hit the same
  fallback as if the challenge was a bad ID.

      iex> Challenges.filter_for_created(%Challenge{status: "created"})
      {:ok, %Challenge{status: "created"}}

      iex> Challenges.filter_for_created(%Challenge{status: "pending"})
      {:error, :not_found}
  """
  def filter_for_created(challenge) do
    case created?(challenge) do
      true ->
        {:ok, challenge}

      false ->
        {:error, :not_found}
    end
  end

  @doc """
  Submit a new challenge for a user
  """
  def old_create(user, params) do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:challenge, create_challenge(user, params))
      |> attach_initial_owner(user)
      |> attach_federal_partners(params)
      |> attach_challenge_owners(params)
      |> attach_documents(params)
      |> Ecto.Multi.run(:logo, fn _repo, %{challenge: challenge} ->
        Logo.maybe_upload_logo(challenge, params)
      end)
      |> Ecto.Multi.run(:winner_image, fn _repo, %{challenge: challenge} ->
        WinnerImage.maybe_upload_winner_image(challenge, params)
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{challenge: challenge}} ->
        {:ok, challenge}

      {:error, :challenge, changeset, _} ->
        {:error, changeset}

      {:error, {:document, _}, _, _} ->
        user
        |> Ecto.build_assoc(:challenges)
        |> Challenge.create_changeset(params, user)
        |> Ecto.Changeset.add_error(:document_ids, "are invalid")
        |> Ecto.Changeset.apply_action(:insert)
    end
  end

  defp create_challenge(user, params) do
    user
    |> Ecto.build_assoc(:challenges)
    |> Map.put(:challenge_owner_users, [])
    |> Map.put(:federal_partners, [])
    |> Map.put(:federal_partner_agencies, [])
    |> Challenge.create_changeset(params, user)
  end

  # Attach federal partners functions
  defp attach_federal_partners(multi, %{"federal_partners" => ""}) do
    attach_federal_partners(multi, %{"federal_partners" => []})
  end

  defp attach_federal_partners(multi, %{"federal_partners" => ids}) do
    ids = Enum.uniq(ids)

    multi =
      Ecto.Multi.run(multi, :delete_agencies, fn _repo, changes ->
        {:ok,
         Repo.delete_all(
           from(fp in FederalPartner, where: fp.challenge_id == ^changes.challenge.id)
         )}
      end)

    Enum.reduce(ids, multi, fn agency_id, multi ->
      Ecto.Multi.run(multi, {:agency, agency_id}, fn _repo, changes ->
        %FederalPartner{}
        |> FederalPartner.changeset(%{
          agency_id: agency_id,
          challenge_id: changes.challenge.id
        })
        |> Repo.insert()
      end)
    end)
  end

  defp attach_federal_partners(multi, _params), do: multi

  # Attach challenge owners functions
  defp attach_initial_owner(multi, user) do
    Ecto.Multi.run(multi, {:user, user.id}, fn _repo, changes ->
      if user.role == "challenge_owner" do
        %ChallengeOwner{}
        |> ChallengeOwner.changeset(%{
          user_id: user.id,
          challenge_id: changes.challenge.id
        })
        |> Repo.insert()
      else
        {:ok, user}
      end
    end)
  end

  # Attach challenge owners functions
  defp attach_challenge_owners(multi, %{challenge_owners: ids}) do
    attach_challenge_owners(multi, %{"challenge_owners" => ids})
  end

  defp attach_challenge_owners(multi, %{"challenge_owners" => ids}) do
    multi =
      Ecto.Multi.run(multi, :delete_owners, fn _repo, changes ->
        {:ok,
         Repo.delete_all(
           from(co in ChallengeOwner, where: co.challenge_id == ^changes.challenge.id)
         )}
      end)

    Enum.reduce(ids, multi, fn user_id, multi ->
      Ecto.Multi.run(multi, {:user, user_id}, fn _repo, changes ->
        %ChallengeOwner{}
        |> ChallengeOwner.changeset(%{
          user_id: user_id,
          challenge_id: changes.challenge.id
        })
        |> Repo.insert()
      end)
    end)
  end

  defp attach_challenge_owners(multi, _params), do: multi

  # Attach supporting document functions
  defp attach_documents(multi, %{document_ids: ids}) do
    attach_documents(multi, %{"document_ids" => ids})
  end

  defp attach_documents(multi, %{"document_ids" => ids}) do
    Enum.reduce(ids, multi, fn document_id, multi ->
      Ecto.Multi.run(multi, {:document, document_id}, fn _repo, changes ->
        document_id
        |> SupportingDocuments.get()
        |> attach_document(changes.challenge)
      end)
    end)
  end

  defp attach_documents(multi, _params), do: multi

  defp attach_document({:ok, document}, challenge) do
    SupportingDocuments.attach_to_challenge(document, challenge, "resources", "")
  end

  defp attach_document(result, _challenge), do: result

  @doc """
  Update a challenge
  """
  def update(challenge, params, current_user) do
    # TODO: Refactor the current_user permissions checking for updating challenge owner
    challenge = Repo.preload(challenge, [:non_federal_partners, :events])

    params =
      params
      |> Map.put_new("challenge_owners", [])
      |> Map.put_new("federal_partners", [])
      |> Map.put_new("non_federal_partners", [])
      |> Map.put_new("events", [])

    changeset =
      if Accounts.is_admin?(current_user) or Accounts.is_super_admin?(current_user) do
        Challenge.admin_update_changeset(challenge, params)
      else
        Challenge.update_changeset(challenge, params)
      end

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:challenge, changeset)
      |> attach_federal_partners(params)
      |> attach_challenge_owners(params)
      |> Ecto.Multi.run(:event, fn _repo, %{challenge: challenge} ->
        maybe_create_event(challenge, changeset)
      end)
      |> Ecto.Multi.run(:logo, fn _repo, %{challenge: challenge} ->
        Logo.maybe_upload_logo(challenge, params)
      end)
      |> Ecto.Multi.run(:winner_image, fn _repo, %{challenge: challenge} ->
        WinnerImage.maybe_upload_winner_image(challenge, params)
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{challenge: challenge}} ->
        {:ok, challenge}

      {:error, _type, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Delete a challenge
  """
  def delete(challenge) do
    Repo.delete(challenge)
  end

  @doc """
  Delete a challenge if allowed
  """
  def delete(challenge, user) do
    if allowed_to_delete(user, challenge) do
      soft_delete(challenge)
    else
      {:error, :not_permitted}
    end
  end

  def soft_delete(challenge) do
    now = DateTime.truncate(Timex.now(), :second)

    challenge
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_change(:deleted_at, now)
    |> Repo.update()
  end

  @doc """
  Checks if a user is allowed to delete a challenge
  """
  def allowed_to_delete(user, challenge) do
    Accounts.has_admin_access?(user) or challenge.status == "draft"
  end

  @doc """
  Checks if a user is allowed to edit a challenge
  """
  def allowed_to_edit(user, challenge) do
    if is_challenge_owner?(user, challenge) or
         Accounts.is_admin?(user) or Accounts.is_super_admin?(user) do
      {:ok, challenge}
    else
      {:error, :not_permitted}
    end
  end

  @doc """
  Checks if a user is in the list of owners for a challenge and not revoked
  """
  def is_challenge_owner?(user, challenge) do
    challenge.challenge_owners
    |> Enum.reject(fn co ->
      !is_nil(co.revoked_at)
    end)
    |> Enum.map(fn co ->
      co.user
    end)
    |> Enum.member?(user)
  end

  @doc """
  Restores access to a user's challlenges
  """
  def restore_access(user, challenge) do
    ChallengeOwner
    |> where([co], co.user_id == ^user.id and co.challenge_id == ^challenge.id)
    |> Repo.update_all(set: [revoked_at: nil])
  end

  defp maybe_create_event(challenge, changeset) do
    case is_nil(Ecto.Changeset.get_change(changeset, :status)) do
      true ->
        {:ok, challenge}

      false ->
        create_status_event(challenge)
        {:ok, challenge}
    end
  end

  @doc """
  Create a new status event when the status changes
  """
  def create_status_event(challenge = %{status: "created"}) do
    Timeline.create_event(challenge, %{
      title: "Created",
      occurs_on: Timeline.today()
    })
  end

  def create_status_event(challenge = %{status: "champion assigned"}) do
    Timeline.create_event(challenge, %{
      title: "Champion Assigned",
      occurs_on: Timeline.today()
    })
  end

  def create_status_event(challenge = %{status: "design"}) do
    Timeline.create_event(challenge, %{
      title: "Design",
      occurs_on: Timeline.today()
    })
  end

  def create_status_event(challenge = %{status: "vetted"}) do
    Timeline.create_event(challenge, %{
      title: "Vetted",
      occurs_on: Timeline.today()
    })
  end

  def create_status_event(_), do: :ok

  @doc """
  Check if a challenge is created

      iex> Challenges.created?(%Challenge{status: "pending"})
      false

      iex> Challenges.created?(%Challenge{status: "created"})
      true

      iex> Challenges.created?(%Challenge{status: "archived"})
      false
  """
  def created?(challenge) do
    challenge.status == "created"
  end

  @doc """
  Checks if the challenge should be publicly accessible. Either published or archived
  """
  def public?(challenge) do
    challenge.status == "created" or challenge.status == "archived"
  end

  @doc """
  Check if a challenge is approvable

      iex> Challenges.publishable?(%Challenge{status: "pending"})
      true

      iex> Challenges.publishable?(%Challenge{status: "approved"})
      false

      iex> Challenges.publishable?(%Challenge{status: "archived"})
      true
  """
  def approvable?(challenge) do
    challenge.status != "approved"
  end

  @doc """
  Check if a challenge is publishable

      iex> Challenges.publishable?(%Challenge{status: "pending"})
      true

      iex> Challenges.publishable?(%Challenge{status: "created"})
      false

      iex> Challenges.publishable?(%Challenge{status: "archived"})
      true
  """
  def publishable?(challenge) do
    challenge.status != "published"
  end

  @doc """
  Approve a challenge

  Sets status to "approved"
  """
  def approve(challenge) do
    changeset = Challenge.approve_changeset(challenge)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:challenge, changeset)
      |> Ecto.Multi.run(:event, fn _repo, %{challenge: challenge} ->
        maybe_create_event(challenge, changeset)
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{challenge: challenge}} ->
        {:ok, challenge}

      {:error, _type, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Publish a challenge

  Sets status to "created"
  """
  def publish(challenge) do
    changeset = Challenge.publish_changeset(challenge)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:challenge, changeset)
      |> Ecto.Multi.run(:event, fn _repo, %{challenge: challenge} ->
        maybe_create_event(challenge, changeset)
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{challenge: challenge}} ->
        {:ok, challenge}

      {:error, _type, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Reject a challenge

  Sets status to "rejected"
  """
  def reject(challenge, message \\ "") do
    changeset = Challenge.reject_changeset(challenge, message)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update(:challenge, changeset)
      |> Repo.transaction()

    case result do
      {:ok, %{challenge: challenge}} ->
        send_challenge_rejection_emails(challenge)
        {:ok, challenge}

      {:error, _type, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp send_challenge_rejection_emails(challenge) do
    Enum.map(challenge.challenge_owner_users, fn owner ->
      owner
      |> Emails.challenge_rejection_email(challenge)
      |> Mailer.deliver_later()
    end)
  end

  @doc """
  Check if a challenge is rejectable
  """
  def rejectable?(challenge) do
    challenge.status != "rejected" &&
      challenge.status != "gsa_review"
  end

  @doc """
  Check if a challenge is archivable

      iex> Challenges.archivable?(%Challenge{status: "pending"})
      true

      iex> Challenges.archivable?(%Challenge{status: "created"})
      true

      iex> Challenges.archivable?(%Challenge{status: "archived"})
      false
  """
  def archivable?(challenge) do
    challenge.status != "archived"
  end

  @doc """
  Archive a challenge

  Sets status to "archived"
  """
  def archive(challenge) do
    challenge
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_change(:status, "archived")
    |> Repo.update()
  end

  def remove_logo(challenge) do
    challenge
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_change(:logo_key, nil)
    |> Ecto.Changeset.put_change(:logo_extension, nil)
    |> Repo.update()
  end

  def remove_winner_image(challenge) do
    challenge
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_change(:winner_image_key, nil)
    |> Ecto.Changeset.put_change(:winner_image_extension, nil)
    |> Repo.update()
  end

  @impl true
  def filter_on_attribute({"search", value}, query) do
    value = "%" <> value <> "%"
    where(query, [c], ilike(c.title, ^value) or ilike(c.description, ^value))
  end

  def filter_on_attribute({"status", value}, query) do
    where(query, [c], c.status == ^value)
  end

  # TODO: Refactor this to use jsonb column more elegantly
  def filter_on_attribute({"types", values}, query) do
    Enum.reduce(values, query, fn value, query ->
      where(query, [c], fragment("? @> ?::jsonb", c.types, ^[value]))
    end)
  end

  def filter_on_attribute({"agency_id", value}, query) do
    where(query, [c], c.agency_id == ^value)
  end

  def filter_on_attribute({"user_id", value}, query) do
    where(query, [c], c.user_id == ^value)
  end

  def filter_on_attribute({"user_ids", ids}, query) do
    query
    |> join(:inner, [c], co in assoc(c, :challenge_owners))
    |> where([co], co.user_id in ^ids)
  end

  def filter_on_attribute({"start_date_start", value}, query) do
    {:ok, datetime} = Timex.parse(value, "{YYYY}-{0M}-{0D}")
    where(query, [c], c.start_date >= ^datetime)
  end

  def filter_on_attribute({"start_date_end", value}, query) do
    {:ok, datetime} = Timex.parse(value, "{YYYY}-{0M}-{0D}")
    where(query, [c], c.start_date <= ^datetime)
  end

  def filter_on_attribute({"end_date_start", value}, query) do
    {:ok, datetime} = Timex.parse(value, "{YYYY}-{0M}-{0D}")
    where(query, [c], c.end_date >= ^datetime)
  end

  def filter_on_attribute({"end_date_end", value}, query) do
    {:ok, datetime} = Timex.parse(value, "{YYYY}-{0M}-{0D}")
    where(query, [c], c.end_date <= ^datetime)
  end

  def filter_on_attribute(_, query), do: query

  def order_on_attribute(query, %{"user" => direction}) do
    query = join(query, :left, [c], a in assoc(c, :user))

    case direction do
      "asc" ->
        order_by(query, [c, a], asc_nulls_last: a.first_name)

      "desc" ->
        order_by(query, [c, a], desc_nulls_last: a.first_name)

      _ ->
        query
    end
  end

  def order_on_attribute(query, %{"agency" => direction}) do
    query = join(query, :left, [c], a in assoc(c, :agency))

    case direction do
      "asc" ->
        order_by(query, [c, a], asc_nulls_last: a.name)

      "desc" ->
        order_by(query, [c, a], desc_nulls_last: a.name)

      _ ->
        query
    end
  end

  def order_on_attribute(query, sort_columns) do
    columns_to_sort =
      Enum.reduce(sort_columns, [], fn {column, direction}, acc ->
        column = String.to_atom(column)

        case direction do
          "asc" ->
            acc ++ [asc_nulls_last: column]

          "desc" ->
            acc ++ [desc_nulls_last: column]

          _ ->
            []
        end
      end)

    order_by(query, [c], ^columns_to_sort)
  end
end
