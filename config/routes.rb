Rails.application.routes.draw do
  root "translation_workspaces#new"

  resource :session, only: %i[new create destroy]
  get "login", to: "sessions#new", as: :login

  get "history", to: "history#index", as: :history
  resources :benchmarks, only: :index
  get "benchmarks/models/:id", to: "benchmarks#show", as: :benchmark_model

  namespace :settings do
    resource :operations, only: :show do
      post :reconcile_stale
    end
    resources :models, except: %i[show destroy] do
      member do
        patch :activate
        patch :deactivate
      end
    end
  end

  resource :translation_workspace, only: %i[new create]
  resources :experiments, only: :show do
    member do
      post :retry_failed
    end
    resources :review_rounds, only: :create
  end
  resources :review_rounds, only: :show do
    member do
      post :retry_failed
    end
    resources :judge_rounds, only: :create
  end
  resources :judge_rounds, only: :show do
    member do
      post :retry_failed
    end
    resource :final_translation, only: :create
  end
  resources :final_translations, only: :show do
    resources :finalization_rounds, only: [] do
      member do
        post :retry_failed
      end
    end
    member do
      patch :save_revision
      post :restore_revision
      post :refine
      post :apply_proposal
      patch :finalize
      patch :reopen
      get :download
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
  get "ready" => "readiness#show", as: :readiness_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
end
