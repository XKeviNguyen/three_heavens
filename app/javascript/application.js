// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
// Must be evaluated before Turbo registers its own popstate listener.
import "history_traversal"
import "@hotwired/turbo-rails"
import "controllers"
