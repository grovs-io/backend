class AndroidServerApiKeySerializer < BaseSerializer
  attributes


  def build(**)
    h = super()
    h["file"] = record.file.attached? ? record.file.filename.to_s : nil
    h
  end
end
