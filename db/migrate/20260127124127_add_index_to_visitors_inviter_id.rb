class AddIndexToVisitorsInviterId < ActiveRecord::Migration[7.0]                                                               
    disable_ddl_transaction!                                                                                                     
                                                                                                                                 
    def change                                                                                                                   
      add_index :visitors, :inviter_id, algorithm: :concurrently, if_not_exists: true                                            
    end                                                                                                                          
end               