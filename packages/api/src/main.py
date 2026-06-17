from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from src.config import settings
from src.routes.chat import router as chat_router
from src.routes.health import router as health_router
from src.services.router_client import RouterClient


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.router_client = RouterClient(
        envoy_url=settings.sr_envoy_url,
        api_url=settings.sr_api_url,
    )
    yield
    await app.state.router_client.close()


app = FastAPI(title="vLLM Semantic Router API", version="0.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.cors_origins.split(",") if o.strip()],
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Content-Type"],
)

app.include_router(health_router)
app.include_router(chat_router)
