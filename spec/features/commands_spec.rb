require 'rails_helper'

RSpec.feature 'Slash Commands' do
  fixtures :all

  before do
    github.reset

    # Set the HEAD commits for some fake branches.
    HEAD('acme-inc/api', 'master',  'ad80a1b3e1a94b98ce99b71a48f811f1')
    HEAD('acme-inc/api', 'topic',   '4c7b474c6e1c81553a16d1082cebfa60')
    HEAD('acme-inc/api', 'failing', '46c2acc4e588924340adcd108cfc948b')
  end

  scenario 'authenticating' do
    stub_request(:post, 'https://github.com/login/oauth/access_token')
      .with(body: { 'client_id' => '', 'client_secret' => '', 'code' => 'code', 'grant_type' => 'authorization_code' })
      .to_return(status: 200, body: { 'access_token' => 'e72e16c7e42f292c6912e7710c838347ae178b4a', 'scope' => 'repo_deployment', 'token_type' => 'bearer' }.to_json, headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, 'https://api.github.com/user')
      .to_return(status: 200, body: { 'id' => 1, 'login' => 'joe' }.to_json, headers: { 'Content-Type' => 'application/json' })

    account = SlackAccount.new(
      id:         'UABCD',
      user_name:  'joe',
      slack_team: slack_teams(:acme)
    )

    command '/deploy help', as: account
    state = command_response.text.gsub(/^.*state=(.*?)\|.*$/, '\\1')
    expect do
      visit "/auth/github/callback?state=#{state}&code=code"
    end.to change { User.count }.by(1)

    command '/deploy help', as: account
    expect(command_response.text).to eq HelpMessage::USAGE.strip
  end

  scenario 'entering an unknown command' do
    command '/deploy foo', as: slack_accounts(:bob)
    expect(command_response.in_channel).to be_falsey
    expect(command_response.text).to eq "I don't know that command. Here's what I do know:\n#{HelpMessage::USAGE}".strip
  end

  scenario 'performing a simple deployment' do
    command '/deploy  acme-inc/api', as: slack_accounts(:david)
    expect(deployment_requests).to eq [
      [users(:david), DeploymentRequest.new(repository: 'acme-inc/api', ref: 'master', environment: 'production')]
    ]
    expect(command_response).to be_in_channel
    expect(command_response.text).to eq 'Created deployment request for <https://github.com/acme-inc/api|acme-inc/api>@<https://github.com/acme-inc/api/commits/ad80a1b3e1a94b98ce99b71a48f811f1|master> to *production* (no change)'

    # David commits something new
    HEAD('acme-inc/api', 'master', 'f5c0df18526b90b9698816ee4b6606e0')

    command '/deploy acme-inc/api', as: slack_accounts(:david)
    expect(command_response.text).to eq 'Created deployment request for <https://github.com/acme-inc/api|acme-inc/api>@<https://github.com/acme-inc/api/commits/f5c0df18526b90b9698816ee4b6606e0|master> to *production* (<https://github.com/acme-inc/api/compare/ad80a1b...f5c0df1|diff>)'
  end

  scenario 'performing a deployment to a specific environment' do
    command '/deploy acme-inc/api  to staging', as: slack_accounts(:david)
    expect(deployment_requests).to eq [
      [users(:david), DeploymentRequest.new(repository: 'acme-inc/api', ref: 'master', environment: 'staging')]
    ]
  end

  scenario 'performing a deployment to an aliased environment' do
    repo = Repository.with_name('acme-inc/api')
    env  = repo.environment('staging')
    env.aliases = ['stage']
    env.save!

    command '/deploy acme-inc/api to stage', as: slack_accounts(:david)
    expect(deployment_requests).to eq [
      [users(:david), DeploymentRequest.new(repository: 'acme-inc/api', ref: 'master', environment: 'staging')]
    ]
  end

  scenario 'performing a deployment using only the repo name' do
    command '/deploy api@topic', as: slack_accounts(:david)
    expect(deployment_requests).to eq [
      [users(:david), DeploymentRequest.new(repository: 'acme-inc/api', ref: 'topic', environment: 'production')]
    ]
  end

  scenario 'performing a deployment of a topic branch' do
    command '/deploy acme-inc/api@topic', as: slack_accounts(:david)
    expect(deployment_requests).to eq [
      [users(:david), DeploymentRequest.new(repository: 'acme-inc/api', ref: 'topic', environment: 'production')]
    ]
  end

  scenario 'performing a deployment of a branch that has failing commit status contexts' do
    expect do
      command '/deploy acme-inc/api@failing', as: slack_accounts(:david)
    end.to_not change { deployment_requests }

    expect(command_response.text).to eq <<-TEXT.strip_heredoc.strip
    The following commit status checks failed:
    * ci
    You can ignore commit status checks by using `/deploy acme-inc/api@failing!`
    TEXT

    expect do
      command '/deploy acme-inc/api@failing!', as: slack_accounts(:david)
    end.to change { deployment_requests.count }.by(1)
  end

  scenario 'attempting to deploy a repo I do not have access to' do
    command '/deploy acme-inc/api', as: slack_accounts(:bob)
    expect(command_response.text).to eq "Sorry, but it looks like you don't have access to acme-inc/api"
  end

  scenario 'attempting to deploy a ref that does not exist on github' do
    command '/deploy acme-inc/api@non-existent-branch', as: slack_accounts(:david)
    expect(command_response.text).to eq 'The ref `non-existent-branch` was not found in acme-inc/api'
  end

  scenario 'locking a branch' do
    command '/deploy lock staging on acme-inc/api', as: slack_accounts(:david)
    expect(command_response.text).to eq 'Locked *staging* on acme-inc/api'

    # Other users shouldn't be able to deploy now.
    expect do
      command '/deploy acme-inc/api to staging', as: slack_accounts(:steve)
    end.to_not change { deployment_requests }
    expect(command_response.text).to eq "*staging* was locked by <@david> less than a minute ago.\nYou can steal the lock with `/deploy lock staging on acme-inc/api!`."

    # But david should be able to deploy.
    expect do
      command '/deploy acme-inc/api to staging', as: slack_accounts(:david)
    end.to change { deployment_requests.count }.by(1)

    command '/deploy unlock staging on acme-inc/api', as: slack_accounts(:david)
    expect(command_response.text).to eq 'Unlocked *staging* on acme-inc/api'

    # Now other users should be able to deploy
    expect do
      command '/deploy acme-inc/api to staging', as: slack_accounts(:steve)
    end.to change { deployment_requests.count }.by(1)
  end

  scenario 'locking a branch with a message' do
    command "/deploy lock staging on acme-inc/api: I'm testing some stuff", as: slack_accounts(:david)
    expect(command_response.text).to eq 'Locked *staging* on acme-inc/api'

    # Other users shouldn't be able to deploy now.
    expect do
      command '/deploy acme-inc/api to staging', as: slack_accounts(:steve)
    end.to_not change { deployment_requests }
    expect(command_response.text).to eq "*staging* was locked by <@david> less than a minute ago.\n> I'm testing some stuff\nYou can steal the lock with `/deploy lock staging on acme-inc/api!`."
  end

  scenario 'stealing a lock' do
    command '/deploy lock staging on acme-inc/api', as: slack_accounts(:david)
    expect(command_response.text).to eq 'Locked *staging* on acme-inc/api'

    command '/deploy lock staging on acme-inc/api', as: slack_accounts(:david)
    expect(command_response.text).to eq '*staging* is already locked'

    command '/deploy lock staging on acme-inc/api', as: slack_accounts(:steve)
    expect(command_response.text).to eq "*staging* was locked by <@david> less than a minute ago.\nYou can steal the lock with `/deploy lock staging on acme-inc/api!`."

    expect do
      command '/deploy acme-inc/api to staging', as: slack_accounts(:steve)
    end.to_not change { deployment_requests }

    command '/deploy lock staging on acme-inc/api!', as: slack_accounts(:steve)
    expect(command_response.text).to eq 'Locked *staging* on acme-inc/api (stolen from <@david>)'

    expect do
      command '/deploy acme-inc/api to staging', as: slack_accounts(:david)
    end.to_not change { deployment_requests }
  end

  scenario 'trying to do something on a repo I dont have access to' do
    command '/deploy lock staging on acme-inc/api', as: slack_accounts(:bob)
    expect(command_response.text).to eq "Sorry, but it looks like you don't have access to acme-inc/api"
  end

  scenario 'finding the environments I can deploy a repo to' do
    command '/deploy where acme-inc/api', as: slack_accounts(:david)
    expect(command_response.text).to eq "I don't know about any environments for acme-inc/api"

    command '/deploy acme-inc/api to staging', as: slack_accounts(:david)

    command '/deploy where acme-inc/api', as: slack_accounts(:david)
    expect(command_response.text).to eq <<-TEXT.strip_heredoc.strip
    I know about these environments for acme-inc/api:
    * staging
    TEXT
  end

  scenario 'trying to /deploy an environment that is configured to auto deploy' do
    repo = Repository.with_name('acme-inc/api')
    environment = repo.environment('production')
    environment.configure_auto_deploy('refs/heads/master')

    expect do
      command '/deploy acme-inc/api@master', as: slack_accounts(:david)
    end.to_not change { deployment_requests }
    expect(command_response.text).to eq "acme-inc/api is configured to automatically deploy `refs/heads/master` to *production*.\nYou can bypass this warning with `/deploy acme-inc/api@master!`"

    expect do
      command '/deploy acme-inc/api@master!', as: slack_accounts(:david)
    end.to change { deployment_requests.count }.by(1)
  end

  xscenario 'debugging exception tracking' do
    command '/deploy boom', as: slack_accounts(:david)
    expect(command_response.text).to eq "Oops! We had a problem running your command, but we've been notified"
  end

  def deployment_requests
    github.requests
  end

  def github
    SlashDeploy.service.github
  end

  # rubocop:disable Style/MethodName
  def HEAD(repository, ref, sha)
    github.HEAD(repository, ref, sha)
  end
end
