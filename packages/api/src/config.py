from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    sr_envoy_url: str = "http://envoy:8801"
    sr_api_url: str = "http://semantic-router:8080"
    llama_stack_url: str = "http://llamastack:8321"
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    cors_origins: str = "http://localhost:5173,http://localhost:3000"


settings = Settings()
