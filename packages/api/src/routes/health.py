from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

router = APIRouter(tags=["health"])


@router.get("/healthz")
async def liveness():
    return {"status": "ok"}


@router.get("/readyz")
async def readiness(request: Request):
    client = request.app.state.router_client
    sr_health = await client.health()
    sr_status = sr_health.get("semantic_router", {}).get("status", "error")
    is_healthy = sr_status in ("ok", "healthy")
    body = {"status": sr_status, "services": sr_health}
    if not is_healthy:
        return JSONResponse(content=body, status_code=503)
    return body
