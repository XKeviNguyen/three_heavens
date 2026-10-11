# An enhanced file input for a Rails form (app/frontend/islands/file_field).
# The fallback is the plain labelled input, which is also what a browser
# without JavaScript submits. Formats and the size limit are the server's.
module FileFieldHelper
  UPLOAD_ACCEPT = (SourceImports::Limits::EXTENSIONS.keys + %w[
    application/pdf text/plain text/markdown application/vnd.openxmlformats-officedocument.wordprocessingml.document
  ]).join(",").freeze

  def upload_field(form, method, label:, paired_text: nil)
    react_island_tag "file-field", props: upload_field_props(form, method, label, paired_text) do
      safe_join([
        form.label(method, label, class: "mt-4 block text-sm font-medium text-slate-700"),
        form.file_field(method, accept: UPLOAD_ACCEPT, class: "mt-2 block w-full text-sm")
      ])
    end
  end

  private

  def upload_field_props(form, method, label, paired_text)
    maximum = SourceImports::Limits::MAX_UPLOAD_BYTES
    {
      id: form.field_id(method),
      name: form.field_name(method),
      label: label,
      accept: UPLOAD_ACCEPT,
      extensions: SourceImports::Limits::FORMATS,
      maxBytes: maximum,
      locale: I18n.locale,
      pairedTextId: paired_text && form.field_id(paired_text),
      messages: t("file_field").merge(help: t("file_field.help", maximum: maximum / 1.megabyte))
    }
  end
end
