// Copyright (c) 2025 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/lang.regexp;
import ballerina/log;

# Represent the execution result of a tool.
public type ToolExecutionResult record {|
    # Return value of the tool
    any|error result;
|};

# This is the tool used by LLMs during reasoning.
# This tool is same as the Tool record, but it has a clear separation between the variables that should be generated with the help of the LLMs and the constants that are defined by the users. 
public type Tool record {|
    # Name of the tool
    string name;
    # Description of the tool
    string description;
    # Variables that should be generated with the help of the LLMs
    map<json> variables?;
    # Constants that are defined by the users
    map<json> constants = {};
    # Function that should be called to execute the tool
    isolated function caller;
|};

public isolated class ToolStore {
    public final map<Tool> & readonly tools;
    private map<()> mcpTools = {};

    # Register tools to the agent. 
    # These tools will be by the LLM to perform tasks.
    #
    # + tools - A list of tools that are available to the LLM
    # + return - An error if the tool is already registered
    public isolated function init((BaseToolKit|ToolConfig|FunctionTool)... tools) returns Error? {
        if tools.length() == 0 {
            self.tools = {};
            return;
        }
        ToolConfig[] toolList = [];
        foreach BaseToolKit|ToolConfig|FunctionTool tool in tools {
            if tool is FunctionTool {
                ToolConfig toolConfig = check getToolConfig(tool);
                toolList.push(toolConfig);
            } else if tool is BaseToolKit {
                ToolConfig[] toolsFromToolKit = tool.getTools(); // TODO remove this after Ballerina fixes nullpointer exception
                if tool is McpToolKit {
                    foreach ToolConfig element in toolsFromToolKit {
                        lock {
                            self.mcpTools[element.name] = ();
                        }
                    }
                }
                toolList.push(...toolsFromToolKit);
            } else {
                toolList.push(tool);
            }
        }
        map<Tool & readonly> toolMap = {};
        check registerTool(toolMap, toolList);
        self.tools = toolMap.cloneReadOnly();
    }

    # execute the tool decided by the LLM.
    #
    # + action - Action object that contains the tool name and inputs
    # + return - ActionResult containing the results of the tool execution or an error if tool execution fails
    public isolated function execute(LlmToolResponse action) returns ToolOutput|LlmInvalidGenerationError|ToolExecutionError {
        string name = action.name;
        map<json>? inputs = action.arguments;
        if !self.tools.hasKey(name) {
            return error ToolNotFoundError("Cannot find the tool.", toolName = name,
                instruction = string `Tool "${name}" does not exists.`
                + string ` Use a tool from the list: ${self.tools.keys().toString()}}`);
        }
        map<json>|error inputValues = mergeInputs(inputs, self.tools.get(name).constants);
        if inputValues is error {
            string instruction = string `Tool "${name}"  execution failed due to invalid inputs provided.` +
                string ` Use the schema to provide inputs: ${self.tools.get(name).variables.toString()}`;
            return error ToolInvalidInputError("Tool is provided with invalid inputs.", inputValues, toolName = name,
                inputs = inputs ?: (), instruction = instruction);
        }
        isolated function caller = self.tools.get(name).caller;
        ToolExecutionResult|error execution;
        lock {
            execution = trap executeTool(caller, self.mcpTools.hasKey(name) 
                ? {
                    params: {
                        name,
                        arguments: inputValues.cloneReadOnly()
                    }
                }
                : inputValues.cloneReadOnly());
        }
        if execution is error {
            return error ToolExecutionError("Tool execution failed.", execution, toolName = name,
                inputs = inputValues.length() == 0 ? {} : inputValues);
        }
        any|error observation = execution.result;
        if observation is http:Response {
            observation = observation.getStatusCodeRecord();
        }
        if observation is stream<anydata, error?> {
            anydata[]|error result = from anydata item in observation
                select item;
            observation = result;
        }
        if observation is anydata {
            return {value: observation};
        }
        if observation !is error {
            return error ToolInvalidOutputError("Tool returns an invalid output. Expected anydata or error.",
                outputType = typeof observation, toolName = name, inputs = inputValues.length() == 0 ? {} : inputValues);
        }
        if observation.message() == "{ballerina/lang.function}IncompatibleArguments" {
            string instruction = string `Tool "${name}"  execution failed due to invalid inputs provided.`
                + string ` Use the schema to provide inputs: ${self.tools.get(name).variables.toString()}`;
            return error ToolInvalidInputError("Tool is provided with invalid inputs.",
                observation, toolName = name, inputs = inputValues.length() == 0 ? {} : inputValues,
                instruction = instruction);
        }
        return {value: observation};
    }
}

isolated function getToolConfig(FunctionTool tool) returns ToolConfig|Error {
    typedesc<FunctionTool> typedescriptor = typeof tool;
    ToolAnnotationConfig? config = typedescriptor.@AgentTool;
    if config is () {
        return error Error("The function '" + getFunctionName(tool) + "' must be annotated with `@ai:AgentTool`.");
    }
    do {
        return {
            name: check config?.name.ensureType(),
            description: check config?.description.ensureType(),
            parameters: check config?.parameters.ensureType(),
            caller: tool
        };
    } on fail error e {
        return error Error("Unable to register the function '" + getFunctionName(tool) + "' as agent tool", e);
    }
}

# Executes an AgentTool.
#
# + tool - Function pointer to the AgentTool
# + llmToolInput - Tool input generated by the LLM
# + return - Result of the tool execution
public isolated function executeTool(FunctionTool tool, map<json> llmToolInput) returns ToolExecutionResult {
    anydata[]|error inputArgs = getInputArgumentsOfFunction(tool, llmToolInput);
    if inputArgs is error {
        return {result: inputArgs};
    }
    any|error result = function:call(tool, ...inputArgs);
    return {result};
}

isolated function getInputArgumentsOfFunction(FunctionTool tool, map<json> inputValues) returns anydata[]|error {
    map<anydata> inputArgs = {};
    map<typedesc<anydata>> typedescs = getToolParameterTypes(tool);
    foreach [string, typedesc<anydata>] [parameterName, typedescriptor] in typedescs.entries() {
        if (inputValues.hasKey(parameterName)) {
            anydata inputArg = check inputValues.get(parameterName).cloneWithType(typedescriptor);
            inputArgs[parameterName] = inputArg;
        }
    }
    map<anydata> argsWithDefaultValues = check trap getArgsWithDefaultValues(tool, inputArgs);
    return argsWithDefaultValues.toArray().cloneReadOnly();
}

isolated function registerTool(map<Tool & readonly> toolMap, ToolConfig[] tools) returns Error? {
    foreach ToolConfig tool in tools {
        string name = tool.name;
        if name.toLowerAscii().matches(FINAL_ANSWER_REGEX) {
            return error Error(string ` Tool name '${name}' is reserved for the 'Final answer'.`);
        }
        if !name.matches(re `^[a-zA-Z0-9_-]{1,64}$`) {
            log:printWarn(string `Tool name '${name}' contains invalid characters. Only alphanumeric, underscore and hyphen are allowed.`);
            if name.length() > 64 {
                name = name.substring(0, 64);
            }
            name = regexp:replaceAll(re `[^a-zA-Z0-9_-]`, name, "_");
        }
        if toolMap.hasKey(name) {
            return error Error("Duplicated tools. Tool name should be unique.", toolName = name);
        }

        map<json>|error? variables = tool.parameters.cloneWithType();
        if variables is error {
            return error Error("Unable to regesiter tool", variables);
        }
        map<json> constants = {};

        if variables is map<json> {
            constants = resolveSchema(variables) ?: {};
        }

        Tool agentTool = {
            name,
            description: regexp:replaceAll(re `\n`, tool.description, " "),
            variables,
            constants,
            caller: tool.caller
        };
        toolMap[name] = agentTool.cloneReadOnly();
    }
}

isolated function resolveSchema(map<json> schema) returns map<json>? {
    // TODO fix when all values are removed as constant, to use null schema
    if schema is ObjectInputSchema {
        map<JsonSubSchema>? properties = schema.properties;
        if properties is () {
            return;
        }
        map<json> values = {};
        foreach [string, JsonSubSchema] [key, subSchema] in properties.entries() {
            json returnedValue = ();
            if subSchema is ArrayInputSchema {
                returnedValue = subSchema?.default;
            }
            else if subSchema is PrimitiveInputSchema {
                returnedValue = subSchema?.default;
            }
            else if subSchema is ConstantValueSchema {
                string tempKey = key; // TODO temporary reference to fix java null pointer issue
                returnedValue = subSchema.'const;
                _ = properties.remove(tempKey);
                string[]? required = schema.required;
                if required !is () {
                    schema.required = from string requiredKey in required
                        where requiredKey != tempKey
                        select requiredKey;
                }
            } else {
                returnedValue = resolveSchema(subSchema);
            }
            if returnedValue !is () {
                values[key] = returnedValue;
            }
        }
        if values.length() > 0 {
            return values;
        }
        return ();
    }
    // skip anyof, oneof, allof, not
    return ();
}

isolated function mergeInputs(map<json>? inputs, map<json> constants) returns map<json> {
    if inputs is () {
        return constants;
    }
    foreach [string, json] [key, value] in constants.entries() {
        if inputs.hasKey(key) {
            json inputValue = inputs[key];
            if inputValue is map<json> && value is map<json> {
                inputs[key] = mergeInputs(inputValue, value);
            }
        } else {
            inputs[key] = value;
        }
    }
    return inputs;
}
