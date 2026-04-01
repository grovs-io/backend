class DownloadableFileSerializer < BaseSerializer
  attributes :id, :name, :updated_at


  def build(**)
    h = super()
    h["file"] = record.file_resource
    h
  end
end
