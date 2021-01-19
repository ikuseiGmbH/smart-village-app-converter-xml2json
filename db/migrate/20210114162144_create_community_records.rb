class CreateCommunityRecords < ActiveRecord::Migration[6.0]
  def change
    create_table :community_records do |t|
      t.string :title
      t.string :data_type
      t.text :json_data, limit: 16.megabytes - 1

      t.timestamps
    end
  end
end
