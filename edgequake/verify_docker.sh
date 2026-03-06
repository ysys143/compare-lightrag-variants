#!/bin/bash

echo "🔍 EdgeQuake Docker Verification"
echo "================================"
echo ""

# 1. Check frontend
echo "1️⃣ Checking frontend..."
FRONTEND_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000)
if [ "$FRONTEND_STATUS" = "200" ]; then
  echo "   ✅ Frontend responding (HTTP 200)"
else
  echo "   ❌ Frontend not accessible (HTTP $FRONTEND_STATUS)"
  exit 1
fi

# 2. Check backend
echo "2️⃣ Checking backend..."
BACKEND_STATUS=$(curl -s http://localhost:8080/health | python3 -c "import sys, json; print(json.load(sys.stdin)['status'])")
if [ "$BACKEND_STATUS" = "healthy" ]; then
  echo "   ✅ Backend healthy"
else
  echo "   ❌ Backend not healthy"
  exit 1
fi

# 3. Check LLM provider
echo "3️⃣ Checking LLM provider..."
LLM_PROVIDER=$(curl -s http://localhost:8080/health | python3 -c "import sys, json; print(json.load(sys.stdin)['llm_provider_name'])")
echo "   ℹ️  Provider: $LLM_PROVIDER"

# 4. Check OPENAI_API_KEY in backend
echo "4️⃣ Checking OPENAI_API_KEY in backend..."
if docker exec edgequake env | grep -q OPENAI_API_KEY; then
  echo "   ✅ OPENAI_API_KEY is set"
else
  echo "   ⚠️  OPENAI_API_KEY not set (using default provider)"
fi

echo ""
echo "================================"
echo "✅ All basic checks passed!"
echo ""
echo "📝 Next steps:"
echo "   1. Open http://localhost:3000 in your browser"
echo "   2. Refresh the page (Cmd+Shift+R)"
echo "   3. Create a new tenant"
echo "   4. Upload a document"
echo "   5. Test queries"
