class DocumentsController < ApplicationController
  CONTENT_TYPES = {
    "txt" => "text/plain; charset=utf-8",
    "md" => "text/plain; charset=utf-8",
    "docx" => SourceImports::Detector::DOCX_MIME
  }.freeze

  def download_original
    document = current_user.documents.find(params[:id])
    raise ActiveRecord::RecordNotFound unless document.source_file.attached?

    send_data document.source_file.download,
              type: CONTENT_TYPES.fetch(document.source_format, "application/octet-stream"),
              disposition: "attachment",
              filename: SourceImports::Filename.safe_original(document.original_filename)
  end
end
