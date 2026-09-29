Rails.application.routes.draw do
  root "landing#show"

  resource :registration, only: %i[new create]
  resource :email_confirmation, only: %i[show create]
  resource :confirmation_resend, only: %i[new create]
  resource :locale, only: :update
  resource :appearance, only: :update
  # Sign in with Google (GIS redirect mode) posts the credential here.
  post "auth/google/callback", to: "auth/google_callbacks#create", as: :google_identity_callback
  post "auth/google/ceremony", to: "auth/google_ceremonies#create", as: :google_identity_ceremony
  namespace :settings do
    resource :account, only: :show do
      resource :google_identity, only: %i[create destroy] do
        delete :pending, action: :cancel_pending
      end
    end
    resources :users, only: :index do
      member do
        patch :grant_managed_ai_access
        patch :revoke_managed_ai_access
      end
    end
  end

  resource :session, only: %i[new create destroy]
  get "login", to: "sessions#new", as: :login

  get "history", to: "history#index", as: :history
  resources :projects, only: %i[index show]
  resources :workflow_profiles, except: :destroy do
    member do
      post :duplicate
      patch :activate
      patch :deactivate
    end
  end
  resources :glossaries, except: :destroy do
    member do
      patch :activate
      patch :deactivate
    end
  end
  resources :methodology_profiles, except: :destroy do
    member do
      patch :activate
      patch :deactivate
    end
  end
  resources :translation_references, except: :destroy do
    member do
      patch :activate
      patch :deactivate
    end
  end
  resources :pipeline_runs, only: :show do
    member do
      patch :stop
    end
  end
  resources :benchmarks, only: :index
  get "benchmarks/models/:id", to: "benchmarks#show", as: :benchmark_model

  namespace :settings do
    resource :operations, only: :show do
      post :reconcile_stale
    end
    resources :models, except: %i[show destroy] do
      collection do
        post :catalog, action: :create_from_catalog
      end
      member do
        patch :activate
        patch :deactivate
      end
    end
  end

  resource :translation_workspace, only: %i[new create]
  resource :translation_workspace_draft, only: %i[create destroy]
  post "translation_workspace/options", to: "translation_workspaces#options", as: :translation_workspace_options

  get "open_router_catalog", to: "open_router_catalog#index", as: :open_router_catalog

  scope "workspace_terminology" do
    get "panel", to: "workspace_terminology#panel", as: :workspace_terminology_panel
    get "new", to: "workspace_terminology#new", as: :new_workspace_terminology
    post "", to: "workspace_terminology#create"
    get "edit", to: "workspace_terminology#edit", as: :edit_workspace_terminology
    patch "", to: "workspace_terminology#update", as: :workspace_terminology
  end
  get "experiments/:experiment_id/repeat", to: "translation_workspaces#repeat", as: :repeat_experiment
  resources :source_imports, only: %i[new create destroy]
  resources :documents, only: [] do
    member do
      get :download_original
    end
  end
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
