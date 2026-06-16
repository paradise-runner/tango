import tango/domain/ticket

pub type WorkspaceRepo {
  WorkspaceRepo(binding_id: String, source: String, path: String)
}

pub type Workspace {
  Workspace(root_path: String, repos: List(WorkspaceRepo))
}

pub type WorkspaceError {
  ProvisionFailed(String)
}

pub type WorkspaceAdapter {
  WorkspaceAdapter(
    ensure: fn(String, ticket.Ticket) -> Result(Workspace, WorkspaceError),
  )
}
