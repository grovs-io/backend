class AddProjectSdkIdentifierIndexToVisitors < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :visitors, %i[project_id sdk_identifier], where: "sdk_identifier IS NOT NULL",
              name: "index_visitors_on_project_id_and_sdk_identifier", algorithm: :concurrently, if_not_exists: true
  end
end
