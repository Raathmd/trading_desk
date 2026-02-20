alias TradingDesk.Auth.User
alias TradingDesk.Repo

users = [
  "marcus.raath@trammo.com"
]

Enum.each(users, fn email ->
  case Repo.get_by(User, email: email) do
    nil ->
      %User{}
      |> User.changeset(%{email: email})
      |> Repo.insert!()
      IO.puts("Inserted user: #{email}")

    _existing ->
      IO.puts("User already exists: #{email}")
  end
end)
