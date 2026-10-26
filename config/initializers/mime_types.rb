# Be sure to restart your server when you modify this file.

# Add new mime types for use in respond_to blocks:
# Mime::Type.register "text/richtext", :rtf

# Marcel labels MP4s with these brands (H.264 and fragmented exports) as QuickTime, refusing valid in-app video.
Marcel::MimeType.extend "video/mp4", magic: [[4, "ftypavc1"], [4, "ftypiso5"], [4, "ftypiso6"], [4, "ftypdash"]]
