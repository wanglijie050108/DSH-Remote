// N3 预留 stub（01 §4.5）：仅调试日志，不做任何应答（应答由官方前端负责）
// 【已核实】approval/request 是 waterfall 监听器（返回即应答，next() 表示委托）；服务名 approval（F17）
export function registerApprovalStub(ctx, log) {
  ctx.on('approval/request', async (req, next) => {
    log('approval request (stub, no answer): ' + JSON.stringify(req?.type ?? req ?? {}).slice(0, 200))
    return next()
  })
}
