module TestPiecewiseFuelCO2

using Test
include(joinpath(@__DIR__, "utilities.jl"))

obj_true = 2341.82308
test_path = "piecewise_fuel"

# Define test inputs
genx_setup = Dict(
    "UCommit" => 2,
    "CO2Cap" => 1,
    "ParameterScale" => 1,
)

# Run the case and get the objective value and tolerance
EP, _, _ = redirect_stdout(devnull) do
    run_genx_case_testing(test_path, genx_setup)
end
obj_test = objective_value(EP)
optimal_tol_rel = get_attribute(EP, "dual_feasibility_tolerance")
optimal_tol = optimal_tol_rel * obj_test  # Convert to absolute tolerance

# Test the objective value
test_result = @test obj_test ≈ obj_true atol = optimal_tol

# Round objective value and tolerance. Write to test log.
obj_test = round_from_tol!(obj_test, optimal_tol)
optimal_tol = round_from_tol!(optimal_tol, optimal_tol)
write_testlog(test_path, obj_test, optimal_tol, test_result)

end # module TestPiecewiseFuelCO2
