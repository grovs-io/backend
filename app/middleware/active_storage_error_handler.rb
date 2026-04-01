class ActiveStorageErrorHandler
  def initialize(app)
    @app = app
  end

  def call(env)
    
    @app.call(env)
  rescue ActiveRecord::RecordNotFound => e
    if env["PATH_INFO"].start_with?("/rails/active_storage")
      request = ActionDispatch::Request.new(env)
      if request.format.json?
        [404, { "Content-Type" => "application/json" }, [{ error: "The requested file could not be found or has been deleted" }.to_json]]
      else
        html_content = <<~HTML
          <!DOCTYPE html>
          <html>
          <head>
            <title>File Not Found</title>
            <style>
              body {
                font-family: Arial, sans-serif;
                text-align: center;
                padding: 50px;
                background-color: #f8f9fa;
                color: #333;
              }
              .container {
                max-width: 600px;
                margin: 0 auto;
                background-color: white;
                padding: 30px;
                border-radius: 8px;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
              }
              h1 {
                color: #d9534f;
              }
              .icon {
                font-size: 60px;
                margin-bottom: 20px;
                color: #d9534f;
              }
              .message {
                margin: 20px 0;
                line-height: 1.5;
              }
              .back-link {
                display: inline-block;
                margin-top: 20px;
                color: #0275d8;
                text-decoration: none;
              }
              .back-link:hover {
                text-decoration: underline;
              }
            </style>
          </head>
          <body>
            <div class="container">
              <h1>File Not Found</h1>
              <div class="message">
                <p>The file you're looking for could not be found or has been deleted.</p>
              </div>
            </div>
          </body>
          </html>
        HTML
        [404, { "Content-Type" => "text/html" }, [html_content]]
      end
    else
      raise e
    end
    
  end
end